// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {VaultLinked} from "./VaultLinked.sol";
import {Network} from "./Network.sol";

/// @notice A daily swarm job, paid in IMD, for each wallet holding one million tokens in this vault.
/// @dev Eligibility is a stake held here, not a spot balance: a spot balance can be lent within one
/// transaction (a transfer chain or a v4 flash take) so one holding would buy one job per hop. The
/// stake that buys a job is locked for the job interval, so one holding buys one job per day however
/// many wallets it passes through. The vault's IMD can only leave as Intake job payments.
contract JobsVault is VaultLinked, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InsufficientHolding();
    error DailyLimit();
    error ActionNotSold();
    error InvalidBody();
    error UnsupportedDecimals();
    error ZeroAmount();
    error StakeLocked();
    error InsufficientStake();

    uint256 public constant MINIMUM_TOKENS = 1_000_000;
    uint256 public constant JOB_INTERVAL = 1 days;
    uint256 public minimumHolding;
    /// @notice Launched tokens each wallet holds in this vault. Only that wallet can take them back.
    mapping(address => uint256) public stakeOf;
    /// @notice Earliest time each wallet may take its stake back: the job interval after its last job.
    mapping(address => uint256) public lockedUntil;
    mapping(address => uint256) public nextJobAt;

    event Staked(address indexed holder, uint256 amount);
    event Unstaked(address indexed holder, uint256 amount);
    event JobRequested(address indexed holder, bytes32 indexed requestId, uint256 price);

    constructor(address vault_) VaultLinked(vault_) {}

    function setToken(address token_) external onlyVault {
        _setToken(token_);
        uint8 decimals = IERC20Metadata(token_).decimals();
        // 1e6 * 1e71 fits uint256; a greater exponent cannot describe a representable threshold.
        if (decimals > 71) revert UnsupportedDecimals();
        minimumHolding = MINIMUM_TOKENS * 10 ** uint256(decimals);
    }

    /// @notice Hold launched tokens here to become eligible. The amount received is what counts.
    function stake(uint256 amount) external nonReentrant {
        if (token == address(0)) revert TokenNotSet();
        if (amount == 0) revert ZeroAmount();
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();
        stakeOf[msg.sender] += received;
        emit Staked(msg.sender, received);
    }

    /// @notice Take your own stake back once the job interval has passed since your last job.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < lockedUntil[msg.sender]) revert StakeLocked();
        uint256 held = stakeOf[msg.sender];
        if (amount > held) revert InsufficientStake();
        stakeOf[msg.sender] = held - amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function requestJob(bytes calldata body) external nonReentrant returns (bytes32 requestId) {
        if (token == address(0)) revert TokenNotSet();
        if (stakeOf[msg.sender] < minimumHolding) revert InsufficientHolding();
        if (block.timestamp < nextJobAt[msg.sender]) revert DailyLimit();
        if (body.length == 0 || body.length > Network.MAX_BODY_BYTES) revert InvalidBody();
        uint256 price = IIntake(Network.INTAKE).priceOf(Network.JOB_ACTION, Network.IMD);
        if (price == 0) revert ActionNotSold();
        nextJobAt[msg.sender] = block.timestamp + JOB_INTERVAL;
        lockedUntil[msg.sender] = block.timestamp + JOB_INTERVAL;
        IERC20(Network.IMD).forceApprove(Network.INTAKE, price);
        requestId = IIntake(Network.INTAKE)
            .request(Network.JOB_ACTION, body, IIntake.Callback(address(0), bytes4(0)), Network.IMD, price);
        IERC20(Network.IMD).forceApprove(Network.INTAKE, 0);
        emit JobRequested(msg.sender, requestId, price);
    }
}
