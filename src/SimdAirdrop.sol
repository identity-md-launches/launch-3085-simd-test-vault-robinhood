// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHookFactory, IVaultBinding, PoolKey} from "./interfaces/IHookFactory.sol";
import {Network} from "./Network.sol";

/// @notice The immutable 457-wallet SIMD TEST remainder allocation, claimable for thirty days.
contract SimdAirdrop is ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant MERKLE_ROOT = 0xe1fc34a5aee64c3cd01e62934929bc57511b5718c2f5ae80072ae25045e50cb4;
    uint256 public constant TOTAL_WEIGHT = 633028988023500000000000000;
    uint256 public constant WALLET_COUNT = 457;
    uint256 public constant CLAIM_WINDOW = 30 days;
    uint64 public constant MIN_LAUNCH_NUMBER = 3076;

    address public immutable vault;
    address public token;
    uint64 public launchNumber;
    uint256 public startBalance;
    uint256 public claimEnd;
    mapping(address => bool) public claimed;

    error InvalidVault();
    error AlreadyBound();
    error InvalidLaunch();
    error InvalidRequester();
    error InvalidPair();
    error LaunchMismatch();
    error VaultNotBound();
    error InsufficientRemainder();
    error NotBound();
    error ClaimClosed();
    error AlreadyClaimed();
    error InvalidProof();
    error ClaimStillOpen();

    event Bound(uint64 indexed launchNumber, address indexed token, uint256 startBalance, uint256 claimEnd);
    event Claimed(address indexed account, uint256 weight, uint256 amount);
    event UnclaimedBurned(uint256 amount);

    constructor(address vault_) {
        if (vault_ == address(0)) revert InvalidVault();
        vault = vault_;
    }

    function bind(uint64 launchNumber_) external nonReentrant {
        if (token != address(0)) revert AlreadyBound();
        if (launchNumber_ <= MIN_LAUNCH_NUMBER) revert InvalidLaunch();
        (PoolKey memory key,,, address requester) = IHookFactory(Network.FACTORY).positionOf(launchNumber_);
        if (requester != vault) revert InvalidRequester();
        address token_;
        if (key.currency0 == Network.IMD) token_ = key.currency1;
        else if (key.currency1 == Network.IMD) token_ = key.currency0;
        else revert InvalidPair();
        if (token_ == address(0) || token_ == Network.IMD || token_.code.length == 0) revert InvalidPair();
        address boundToken = IVaultBinding(vault).token();
        // A factory requester can transfer its role. Requiring the vault's own one-time binding
        // prevents someone transferring an unrelated position to this vault and front-running bind.
        if (boundToken == address(0)) revert VaultNotBound();
        if (boundToken != token_ || IVaultBinding(vault).launchNumber() != launchNumber_) {
            revert LaunchMismatch();
        }
        uint256 balance = IERC20(token_).balanceOf(address(this));
        if (balance < TOTAL_WEIGHT) revert InsufficientRemainder();
        token = token_;
        launchNumber = launchNumber_;
        startBalance = balance;
        claimEnd = block.timestamp + CLAIM_WINDOW;
        emit Bound(launchNumber_, token_, balance, claimEnd);
    }

    function amountOf(uint256 weight) public view returns (uint256) {
        return Math.mulDiv(startBalance, weight, TOTAL_WEIGHT);
    }

    function claim(uint256 weight, bytes32[] calldata proof) external nonReentrant {
        if (token == address(0)) revert NotBound();
        if (block.timestamp >= claimEnd) revert ClaimClosed();
        if (claimed[msg.sender]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, weight))));
        if (weight == 0 || weight > TOTAL_WEIGHT || !MerkleProof.verifyCalldata(proof, MERKLE_ROOT, leaf)) {
            revert InvalidProof();
        }
        claimed[msg.sender] = true;
        uint256 amount = amountOf(weight);
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, weight, amount);
    }

    function burnUnclaimed() external nonReentrant {
        if (token == address(0)) revert NotBound();
        if (block.timestamp < claimEnd) revert ClaimStillOpen();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(Network.BURN, amount);
        emit UnclaimedBurned(amount);
    }
}
