// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Address fields have the same ABI as Uniswap v4's Currency and IHooks value types.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IHookFactory {
    function positionOf(uint64 launchNumber)
        external
        view
        returns (PoolKey memory key, int24 tickLower, int24 tickUpper, address requester);
    function claimFees(uint64 launchNumber) external;
    function poolManager() external view returns (address);
}

interface IVaultBinding {
    function token() external view returns (address);
    function launchNumber() external view returns (uint64);
}

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}
