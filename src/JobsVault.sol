// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {VaultLinked} from "./VaultLinked.sol";
import {Network} from "./Network.sol";

/// @notice A daily swarm job, paid in IMD, for each wallet currently holding one million tokens.
contract JobsVault is VaultLinked, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InsufficientHolding();
    error DailyLimit();
    error ActionNotSold();
    error InvalidBody();
    error UnsupportedDecimals();

    uint256 public constant MINIMUM_TOKENS = 1_000_000;
    uint256 public constant JOB_INTERVAL = 1 days;
    uint256 public minimumHolding;
    mapping(address => uint256) public nextJobAt;

    event JobRequested(address indexed holder, bytes32 indexed requestId, uint256 price);

    constructor(address vault_) VaultLinked(vault_) {}

    function setToken(address token_) external onlyVault {
        _setToken(token_);
        uint8 decimals = IERC20Metadata(token_).decimals();
        // 1e6 * 1e71 fits uint256; a greater exponent cannot describe a representable threshold.
        if (decimals > 71) revert UnsupportedDecimals();
        minimumHolding = MINIMUM_TOKENS * 10 ** uint256(decimals);
    }

    function requestJob(bytes calldata body) external nonReentrant returns (bytes32 requestId) {
        if (token == address(0)) revert TokenNotSet();
        if (IERC20(token).balanceOf(msg.sender) < minimumHolding) revert InsufficientHolding();
        if (block.timestamp < nextJobAt[msg.sender]) revert DailyLimit();
        if (body.length == 0 || body.length > Network.MAX_BODY_BYTES) revert InvalidBody();
        uint256 price = IIntake(Network.INTAKE).priceOf(Network.JOB_ACTION, Network.IMD);
        if (price == 0) revert ActionNotSold();
        nextJobAt[msg.sender] = block.timestamp + JOB_INTERVAL;
        IERC20(Network.IMD).forceApprove(Network.INTAKE, price);
        requestId = IIntake(Network.INTAKE)
            .request(Network.JOB_ACTION, body, IIntake.Callback(address(0), bytes4(0)), Network.IMD, price);
        IERC20(Network.IMD).forceApprove(Network.INTAKE, 0);
        emit JobRequested(msg.sender, requestId, price);
    }
}
