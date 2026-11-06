// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./oracle/OracleAttestation.sol";
import {OracleQuestion} from "./oracle/OracleQuestion.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {IHookFactory, IArbSys} from "./interfaces/IHookFactory.sol";
import {VaultLinked} from "./VaultLinked.sol";
import {Network} from "./Network.sol";

/// @notice Weekly IMD pots with oracle-attested allocations derived from deposit-block token balances.
contract HolderRewards is VaultLinked, OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant EPOCH_WINDOW = 28 days;
    uint256 public constant RETRY_DELAY = 1 days;
    uint16 public constant PANEL_SIZE = 30;
    uint16 public constant QUORUM = 20;
    uint256 public constant ANSWER_VALIDITY = 1 days;
    uint256 public constant REQUEST_GAS = 2_000_000;

    struct Epoch {
        // Net IMD reserved, after oracle fees and any unallocated carry moved to a newer epoch.
        uint256 pot;
        uint256 claimed;
        // Fixed budget in the current request/root. Rollover additions cannot enlarge its leaves.
        uint256 allocationBudget;
        // Additions after the current request: included on retry, or carried to the next deposit.
        uint256 unallocated;
        uint256 openedAt;
        uint256 snapshotBlock;
        uint256 lastAttempt;
        bytes32 requestId;
        bytes32 questionHash;
        bytes32 root;
        bool attempted;
        bool closed;
    }

    address public immutable jobsVault;
    address public immutable simdAirdrop;
    address public poolManager;
    uint256 public currentEpoch;
    /// @notice Sum of pot - claimed of all open epochs. Unsolicited IMD joins the next vault deposit.
    uint256 public reserved;
    mapping(uint256 => Epoch) private _epochs;
    mapping(bytes32 => uint256) public requestEpoch;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    error OnlySelf();
    error OnlyIntake();
    error UnknownEpoch();
    error EpochClosed();
    error TooSoon();
    error AlreadyAnswered();
    error CannotRequest();
    error UnknownRequest();
    error WrongQuestion();
    error InvalidAttestation();
    error RootNotReady();
    error InvalidProof();
    error AlreadyClaimed();
    error PotExceeded();

    event EpochOpened(uint256 indexed epoch, uint256 snapshotBlock, uint256 amount);
    event OracleRequested(
        uint256 indexed epoch, bytes32 indexed requestId, bytes32 questionHash, uint256 fee
    );
    event OracleDeferred(uint256 indexed epoch);
    event RootReceived(uint256 indexed epoch, bytes32 root, uint256 allocationBudget);
    event Claimed(uint256 indexed epoch, address indexed holder, uint256 amount);
    event RolledOver(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 amount);
    event UnallocatedCarried(uint256 indexed fromEpoch, uint256 indexed toEpoch, uint256 amount);

    constructor(address vault_, address jobsVault_, address simdAirdrop_)
        VaultLinked(vault_)
        OracleAttestationConsumer(Network.ORACLE_SIGNER)
    {
        if (jobsVault_ == address(0) || simdAirdrop_ == address(0)) {
            revert InvalidAddress();
        }
        jobsVault = jobsVault_;
        simdAirdrop = simdAirdrop_;
    }

    function setToken(address token_) external onlyVault {
        _setToken(token_);
        poolManager = IHookFactory(Network.FACTORY).poolManager();
        if (poolManager == address(0)) revert InvalidAddress();
    }

    function epoch(uint256 id) external view returns (Epoch memory) {
        return _epochs[id];
    }

    /// @notice Called just after the vault transfers IMD. Counts actual unreserved balance once.
    /// @dev A failed/underfunded request is caught inside this function, preserving the deposit.
    function notifyDeposit() external onlyVault nonReentrant {
        if (token == address(0)) revert TokenNotSet();
        uint256 received = IERC20(Network.IMD).balanceOf(address(this)) - reserved;
        if (received == 0) return;
        reserved += received;
        uint256 previous = currentEpoch;
        uint256 carry = 0;
        if (previous != 0) {
            Epoch storage old = _epochs[previous];
            if (!old.closed) {
                if (old.requestId == bytes32(0) && old.root == bytes32(0)) {
                    // No fee was paid successfully and no allocation exists. Small pots accumulate.
                    carry = old.pot - old.claimed;
                    old.closed = true;
                } else {
                    carry = old.unallocated;
                    old.pot -= carry;
                }
                old.unallocated = 0;
            }
        }
        uint256 id = _openEpoch(received + carry);
        if (carry != 0) emit UnallocatedCarried(previous, id, carry);
        _attempt(id);
    }

    /// @notice Retry a reverted/lost/refused request after one day, or first ask for a rollover epoch.
    /// @dev Each successful ask spends another live price from this epoch alone. Old ids are invalidated.
    function retryOracle(uint256 id) external nonReentrant {
        Epoch storage e = _liveEpoch(id);
        if (e.root != bytes32(0)) revert AlreadyAnswered();
        if (e.attempted && block.timestamp < e.lastAttempt + RETRY_DELAY) revert TooSoon();
        if (e.requestId != bytes32(0)) {
            delete requestEpoch[e.requestId];
            e.requestId = bytes32(0);
        }
        _attempt(id);
    }

    function _attempt(uint256 id) private {
        Epoch storage e = _epochs[id];
        e.attempted = true;
        e.lastAttempt = block.timestamp;
        // An external self-call makes price lookup, approval, request and accounting one revertible unit.
        // The gas bound keeps an unavailable Intake from exhausting the distribution transaction.
        try this.submitOracle{gas: REQUEST_GAS}(id) {}
        catch {
            emit OracleDeferred(id);
        }
    }

    /// @dev Self-only helper; never an independent spending path.
    function submitOracle(uint256 id) external {
        if (msg.sender != address(this)) revert OnlySelf();
        Epoch storage e = _epochs[id];
        uint256 price = IIntake(Network.INTAKE).priceOf(Network.ORACLE_ACTION, Network.IMD);
        if (price == 0 || price >= e.pot) revert CannotRequest();
        e.pot -= price;
        reserved -= price;
        e.allocationBudget = e.pot;
        e.unallocated = 0;
        OracleQuestion.Question memory q = _question(id, e.allocationBudget);
        bytes32 questionHash = OracleQuestion.hash(q);
        bytes memory body = OracleQuestion.body(q, PANEL_SIZE, QUORUM, ANSWER_VALIDITY);
        IERC20(Network.IMD).forceApprove(Network.INTAKE, price);
        bytes32 requestId = IIntake(Network.INTAKE)
            .request(
                Network.ORACLE_ACTION,
                body,
                IIntake.Callback(address(this), this.onOracleResult.selector),
                Network.IMD,
                price
            );
        IERC20(Network.IMD).forceApprove(Network.INTAKE, 0);
        if (requestId == bytes32(0) || requestEpoch[requestId] != 0) revert CannotRequest();
        e.requestId = requestId;
        e.questionHash = questionHash;
        requestEpoch[requestId] = id;
        emit OracleRequested(id, requestId, questionHash, price);
    }

    /// @notice Canonical IdentityMD callback. Only a signed answer to this epoch's current ask is accepted.
    function onOracleResult(
        bytes32 requestId,
        OracleAttestation.Attestation calldata a,
        bytes calldata signature
    ) external nonReentrant {
        if (msg.sender != Network.INTAKE) revert OnlyIntake();
        uint256 id = requestEpoch[requestId];
        if (id == 0) revert UnknownRequest();
        Epoch storage e = _liveEpoch(id);
        if (a.questionHash != e.questionHash) revert WrongQuestion();
        if (
            a.chainId != block.chainid || a.fromBlock != e.snapshotBlock || a.toBlock != e.snapshotBlock
                || a.panelSize < PANEL_SIZE || a.quorum < QUORUM || a.agreed < a.quorum
                || a.agreed > a.panelSize || uint256(a.issuedAt) + ISSUED_AT_TOLERANCE < e.lastAttempt
                || a.expiresAt < a.issuedAt || a.answer.length != 32
        ) revert InvalidAttestation();
        _verifyAttestation(a, signature);
        _consume(a.requestId);
        bytes32 root = decodeBytes32(a);
        if (root == bytes32(0)) revert InvalidAttestation();
        delete requestEpoch[requestId];
        e.root = root;
        emit RootReceived(id, root, e.allocationBudget);
    }

    /// @notice Claim the IMD amount in your deposit-block allocation, independent of today's holdings.
    function claim(uint256 id, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Epoch storage e = _liveEpoch(id);
        if (e.root == bytes32(0)) revert RootNotReady();
        if (hasClaimed[id][msg.sender]) revert AlreadyClaimed();
        if (amount == 0 || amount > e.pot - e.claimed || amount > e.allocationBudget - e.claimed) {
            revert PotExceeded();
        }
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        if (!MerkleProof.verifyCalldata(proof, e.root, leaf)) revert InvalidProof();
        hasClaimed[id][msg.sender] = true;
        e.claimed += amount;
        reserved -= amount;
        IERC20(Network.IMD).safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    /// @notice Close a 28-day-old epoch and credit exactly its unclaimed net pot to the current epoch.
    /// @dev No fee is charged by rollover. If no live current epoch exists, a fresh one is opened.
    function rollover(uint256 id) external nonReentrant {
        if (id == 0 || id > currentEpoch) revert UnknownEpoch();
        Epoch storage e = _epochs[id];
        if (e.closed) revert EpochClosed();
        if (block.timestamp < e.openedAt + EPOCH_WINDOW) revert TooSoon();
        e.closed = true;
        if (e.requestId != bytes32(0)) delete requestEpoch[e.requestId];
        uint256 remaining = e.pot - e.claimed;
        e.unallocated = 0;
        Epoch storage latest = _epochs[currentEpoch];
        uint256 target = currentEpoch;
        if (latest.closed || block.timestamp >= latest.openedAt + EPOCH_WINDOW) target = _openEpoch(0);
        Epoch storage destination = _epochs[target];
        destination.pot += remaining;
        if (destination.requestId != bytes32(0) || destination.root != bytes32(0)) {
            destination.unallocated += remaining;
        }
        emit RolledOver(id, target, remaining);
    }

    function _liveEpoch(uint256 id) private view returns (Epoch storage e) {
        if (id == 0 || id > currentEpoch) revert UnknownEpoch();
        e = _epochs[id];
        if (e.closed || block.timestamp >= e.openedAt + EPOCH_WINDOW) revert EpochClosed();
    }

    function _openEpoch(uint256 pot) private returns (uint256 id) {
        id = ++currentEpoch;
        Epoch storage e = _epochs[id];
        e.pot = pot;
        e.openedAt = block.timestamp;
        // Robinhood is Arbitrum Orbit: the snapshot must use L2 RPC block numbers, not L1 block.number.
        e.snapshotBlock = snapshotHead();
        emit EpochOpened(id, e.snapshotBlock, pot);
    }

    /// @notice L2 block number on Robinhood; ordinary EVM block number where ArbSys is absent.
    /// @dev The fallback also lets offline EVM runners without Arbitrum precompiles use vm.roll.
    function snapshotHead() public view returns (uint256) {
        (bool ok, bytes memory data) = address(100).staticcall(abi.encodeCall(IArbSys.arbBlockNumber, ()));
        if (ok && data.length == 32) return abi.decode(data, (uint256));
        return block.number;
    }

    /// @notice Preview the exact question document and body of the outstanding allocation.
    function oracleBody(uint256 id) external view returns (bytes memory) {
        if (id == 0 || id > currentEpoch) revert UnknownEpoch();
        return
            OracleQuestion.body(
                _question(id, _epochs[id].allocationBudget), PANEL_SIZE, QUORUM, ANSWER_VALIDITY
            );
    }

    function _question(uint256 id, uint256 budget) private view returns (OracleQuestion.Question memory q) {
        q.question = string.concat(
            "What is the bytes32 OpenZeppelin StandardMerkleTree root of the IMD claim allocations for SIMD TEST 2 holder rewards contract ",
            Strings.toHexString(address(this)),
            ", epoch ",
            Strings.toString(id),
            ", using token ",
            Strings.toHexString(token),
            " balances at the end of the window block and the allocation, exclusions, holders, leaves and tree definitions?"
        );
        q.chainId = block.chainid;
        q.fromBlock = _epochs[id].snapshotBlock;
        q.toBlock = q.fromBlock;
        q.answerType = OracleAttestation.ANSWER_BYTES32;
        q.definitions = new OracleQuestion.Definition[](5);
        q.definitions[0] = OracleQuestion.Definition(
            "allocation",
            string.concat(
                "Budget B is ",
                Strings.toString(budget),
                " IMD base units. For each eligible holder with token balance w, amount=floor(B*w/W), where W is the sum of eligible balances. Use exact integers. Omit zero amounts. If none, return bytes32(uint256(1)); no claims exist."
            )
        );
        q.definitions[1] = OracleQuestion.Definition(
            "exclusions",
            string.concat(
                "Exclude every liquidity pool contract holding this token, the zero and dead burn addresses, and these addresses: ",
                Strings.toHexString(poolManager),
                ",",
                Strings.toHexString(Network.FACTORY),
                ",",
                Strings.toHexString(vault),
                ",",
                Strings.toHexString(address(this)),
                ",",
                Strings.toHexString(jobsVault),
                ",",
                Strings.toHexString(simdAirdrop),
                "."
            )
        );
        q.definitions[2] = OracleQuestion.Definition(
            "holders",
            "All addresses with positive raw ERC20 balanceOf at the end of the specified L2 block, after exclusions. Discover holders from Transfer logs since token creation, then verify historical balances. No current balances or supply-based denominator."
        );
        q.definitions[3] = OracleQuestion.Definition(
            "leaves",
            "One leaf per eligible address: keccak256(bytes.concat(keccak256(abi.encode(address account,uint256 amount)))). Amount is its IMD allocation, not its token balance. Publish the account, snapshot balance, amount and proof for every leaf as public evidence."
        );
        q.definitions[4] = OracleQuestion.Definition(
            "tree",
            "OpenZeppelin StandardMerkleTree.of(values,[address,uint256]) with sortLeaves=true. Sort leaves by hash ascending; place them from last node backwards in the complete 2*n-1 node tree. Parent=keccak256(concat(min(childA,childB),max(childA,childB))). Single leaf root is that leaf."
        );
    }
}
