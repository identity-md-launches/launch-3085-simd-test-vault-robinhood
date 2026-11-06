// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {IHookFactory, PoolKey} from "../../src/interfaces/IHookFactory.sol";
import {Network} from "../../src/Network.sol";

contract MockToken is ERC20 {
    uint8 private immutable _decimals;
    bool public failTransfers;
    address public reenterTarget;
    bytes public reenterData;
    bool public reentrySucceeded;

    constructor(uint8 decimals_) ERC20("Fixture token", "FIX") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfers(bool value) external {
        failTransfers = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfers) return false;
        if (reenterTarget != address(0)) (reentrySucceeded,) = reenterTarget.call(reenterData);
        return super.transfer(to, value);
    }
}

contract MockIntake is IIntake {
    struct Request {
        address payer;
        bytes32 action;
        bytes body;
        bytes32 bodyHash;
        Callback callback;
        address asset;
        uint256 amount;
    }

    mapping(bytes32 => uint256) public prices;
    mapping(bytes32 => Request) private _requests;
    uint256 public nonce;
    bytes32 public lastId;
    bool public failPrice;
    bool public failRequest;
    bool public useAllGas;
    address public reenterTarget;
    bytes public reenterData;
    bool public reentrySucceeded;

    function setPrice(bytes32 action, uint256 amount) external {
        prices[action] = amount;
    }

    function setFailure(bool priceFailure, bool requestFailure) external {
        failPrice = priceFailure;
        failRequest = requestFailure;
    }

    function setUseAllGas(bool value) external {
        useAllGas = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256) {
        require(!failPrice, "price unavailable");
        require(asset == Network.IMD, "wrong asset");
        return prices[action];
    }

    function request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(!failRequest, "request unavailable");
        if (useAllGas) {
            assembly { invalid() }
        }
        require(msg.value == 0 && asset == Network.IMD, "wrong asset");
        require(prices[action] != 0 && amount == prices[action], "wrong price");
        require(body.length != 0 && body.length <= 16_384, "body length");
        require(IERC20(asset).allowance(msg.sender, address(this)) == amount, "not exact approval");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "payment failed");
        if (reenterTarget != address(0)) (reentrySucceeded,) = reenterTarget.call(reenterData);
        id = keccak256(abi.encode(msg.sender, ++nonce));
        // The real Intake emits the body rather than storing it. Keep short job/launch bodies for
        // convenient assertions, and hash the large oracle body so the mock respects its gas budget.
        _requests[id] = Request(
            msg.sender,
            action,
            action == Network.ORACLE_ACTION ? bytes("") : body,
            keccak256(body),
            callback,
            asset,
            amount
        );
        lastId = id;
    }

    function getRequest(bytes32 id) external view returns (Request memory) {
        return _requests[id];
    }

    function deliver(bytes32 id, bytes calldata data) external returns (bool ok, bytes memory result) {
        Callback memory cb = _requests[id].callback;
        (ok, result) = cb.target.call{gas: 200_000}(bytes.concat(cb.selector, data));
    }
}

contract MockFactory is IHookFactory {
    struct Position {
        PoolKey key;
        address requester;
    }
    mapping(uint64 => Position) private positions;
    address public poolManager;
    uint256 public imdPayout;
    uint256 public tokenPayout;
    uint256 public nativePayout;
    bool public fails;
    bool public useAllGas;
    uint256 public claims;
    address public reenterTarget;
    bytes public reenterData;
    bool public reentrySucceeded;

    function setManager(address manager) external {
        poolManager = manager;
    }

    function setPosition(uint64 id, PoolKey calldata key, address requester) external {
        positions[id] = Position(key, requester);
    }

    function setPayouts(uint256 imd_, uint256 token_, uint256 eth_) external {
        imdPayout = imd_;
        tokenPayout = token_;
        nativePayout = eth_;
    }

    function setFails(bool value) external {
        fails = value;
    }

    function setUseAllGas(bool value) external {
        useAllGas = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function positionOf(uint64 id) external view returns (PoolKey memory, int24, int24, address) {
        return (positions[id].key, -60, 60, positions[id].requester);
    }

    function claimFees(uint64 id) external {
        require(!fails, "fees unavailable");
        if (useAllGas) {
            assembly { invalid() }
        }
        ++claims;
        Position memory p = positions[id];
        address t = p.key.currency0 == Network.IMD ? p.key.currency1 : p.key.currency0;
        uint256 i = imdPayout;
        uint256 b = tokenPayout;
        uint256 n = nativePayout;
        imdPayout = 0;
        tokenPayout = 0;
        nativePayout = 0;
        if (reenterTarget != address(0)) (reentrySucceeded,) = reenterTarget.call(reenterData);
        if (i != 0) require(IERC20(Network.IMD).transfer(p.requester, i));
        if (b != 0) require(IERC20(t).transfer(p.requester, b));
        if (n != 0) {
            (bool ok,) = p.requester.call{value: n}("");
            require(ok, "native rejected");
        }
    }
    receive() external payable {}
}

/// @dev Test-only ERC-1271 stand-in at the fixed production oracle address; validates actual test signatures.
contract MockSigner {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(hash, signature);
        return
            err == ECDSA.RecoverError.NoError && recovered == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract RejectNative {
    receive() external payable {
        revert("reject");
    }
}

contract ConsumeNativeGas {
    receive() external payable {
        assembly { invalid() }
    }
}

contract ReenterNative {
    address public immutable target;
    bool public succeeded;

    constructor(address target_) {
        target = target_;
    }

    receive() external payable {
        (succeeded,) = target.call(abi.encodeWithSignature("distribute()"));
    }
}
