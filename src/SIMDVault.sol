// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {IHookFactory, PoolKey} from "./interfaces/IHookFactory.sol";
import {HolderRewards} from "./HolderRewards.sol";
import {JobsVault} from "./JobsVault.sol";
import {SimdAirdrop} from "./SimdAirdrop.sol";
import {Network} from "./Network.sol";

/// @notice Immutable launch requester and weekly fee splitter for SIMD TEST 2 - DO NOT BUY.
contract SIMDVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    HolderRewards public immutable holderRewards;
    JobsVault public immutable jobsVault;
    SimdAirdrop public immutable simdAirdrop;
    address public token;
    uint64 public launchNumber;
    bool public launched;
    bool public bound;
    uint256 public nextDistributionAt;
    bytes32 public launchRequestId;

    uint256 public constant DISTRIBUTION_INTERVAL = 7 days;
    uint256 public constant NATIVE_PUSH_GAS = 50_000;
    uint256 public constant CLAIM_FEES_GAS = 1_000_000;

    error OnlyDev();
    error AlreadyLaunched();
    error AlreadyBound();
    error NotBound();
    error InvalidRequester();
    error InvalidLaunch();
    error InvalidToken();
    error InvalidPair();
    error LaunchMismatch();
    error TooSoon();
    error ActionNotSold();
    error InvalidBody();

    event LaunchRequested(bytes32 indexed requestId, uint256 price);
    event LaunchBound(uint64 indexed launchNumber, address indexed token);
    event FeeClaimFailed(uint64 indexed launchNumber);
    event Distributed(
        uint256 holderAmount, uint256 jobsAmount, uint256 devAmount, uint256 marketingAmount, uint256 burned
    );
    event NativePayout(uint256 amount, bool delivered);

    constructor() {
        simdAirdrop = new SimdAirdrop(address(this));
        jobsVault = new JobsVault(address(this));
        holderRewards = new HolderRewards(address(this), address(jobsVault), address(simdAirdrop));
    }

    modifier onlyDev() {
        if (msg.sender != Network.DEV) revert OnlyDev();
        _;
    }

    function launch(bytes calldata body) external onlyDev nonReentrant returns (bytes32 requestId) {
        if (launched) revert AlreadyLaunched();
        if (body.length == 0 || body.length > Network.MAX_BODY_BYTES) revert InvalidBody();
        uint256 price = IIntake(Network.INTAKE).priceOf(Network.LAUNCH_ACTION, Network.IMD);
        if (price == 0) revert ActionNotSold();
        launched = true;
        IERC20(Network.IMD).forceApprove(Network.INTAKE, price);
        requestId = IIntake(Network.INTAKE)
            .request(Network.LAUNCH_ACTION, body, IIntake.Callback(address(0), bytes4(0)), Network.IMD, price);
        IERC20(Network.IMD).forceApprove(Network.INTAKE, 0);
        launchRequestId = requestId;
        emit LaunchRequested(requestId, price);
    }

    /// @dev Accepts only a launch the airdrop can also bind: newer than the previous test launch
    /// and paired with IMD. Both bindings are one-shot, so a mismatch would strand the remainder.
    function bindLaunch(uint64 launchNumber_, address token_) external onlyDev nonReentrant {
        if (bound) revert AlreadyBound();
        (PoolKey memory key,,, address requester) = IHookFactory(Network.FACTORY).positionOf(launchNumber_);
        if (requester != address(this)) revert InvalidRequester();
        if (launchNumber_ <= simdAirdrop.MIN_LAUNCH_NUMBER()) revert InvalidLaunch();
        if (
            token_ == address(0) || token_ == Network.IMD || token_.code.length == 0
                || (token_ != key.currency0 && token_ != key.currency1)
        ) revert InvalidToken();
        address other = token_ == key.currency0 ? key.currency1 : key.currency0;
        if (other != Network.IMD) revert InvalidPair();
        if (simdAirdrop.token() != address(0)) {
            if (simdAirdrop.token() != token_ || simdAirdrop.launchNumber() != launchNumber_) {
                revert LaunchMismatch();
            }
        }
        bound = true;
        launchNumber = launchNumber_;
        token = token_;
        holderRewards.setToken(token_);
        jobsVault.setToken(token_);
        emit LaunchBound(launchNumber_, token_);
    }

    function distribute() external nonReentrant {
        if (!bound) revert NotBound();
        if (block.timestamp < nextDistributionAt) revert TooSoon();
        nextDistributionAt = block.timestamp + DISTRIBUTION_INTERVAL;
        try IHookFactory(Network.FACTORY).claimFees{gas: CLAIM_FEES_GAS}(launchNumber) {}
        catch {
            emit FeeClaimFailed(launchNumber);
        }
        IERC20 imd = IERC20(Network.IMD);
        uint256 balance = imd.balanceOf(address(this));
        uint256 holderAmount = Math.mulDiv(balance, 4000, 10_000);
        uint256 jobsAmount = Math.mulDiv(balance, 2572, 10_000);
        uint256 devAmount = Math.mulDiv(balance, 1714, 10_000);
        uint256 marketingAmount = Math.mulDiv(balance, 1714, 10_000);
        if (holderAmount != 0) {
            imd.safeTransfer(address(holderRewards), holderAmount);
            holderRewards.notifyDeposit();
        }
        if (jobsAmount != 0) imd.safeTransfer(address(jobsVault), jobsAmount);
        if (devAmount != 0) imd.safeTransfer(Network.DEV, devAmount);
        if (marketingAmount != 0) imd.safeTransfer(Network.MARKETING, marketingAmount);
        uint256 burnAmount = IERC20(token).balanceOf(address(this));
        if (burnAmount != 0) IERC20(token).safeTransfer(Network.BURN, burnAmount);
        uint256 nativeBalance = address(this).balance;
        if (nativeBalance != 0) {
            (bool sent,) = Network.MARKETING.call{value: nativeBalance, gas: NATIVE_PUSH_GAS}("");
            emit NativePayout(nativeBalance, sent);
        }
        emit Distributed(holderAmount, jobsAmount, devAmount, marketingAmount, burnAmount);
    }

    receive() external payable {}
}
