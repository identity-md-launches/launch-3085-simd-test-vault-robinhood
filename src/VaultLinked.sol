// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Network} from "./Network.sol";

abstract contract VaultLinked {
    error OnlyVault();
    error InvalidAddress();
    error TokenAlreadySet();
    error TokenNotSet();

    address public immutable vault;
    address public token;

    event TokenSet(address indexed token);

    constructor(address vault_) {
        if (vault_ == address(0)) revert InvalidAddress();
        vault = vault_;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function _setToken(address token_) internal {
        if (token != address(0)) revert TokenAlreadySet();
        if (token_ == address(0) || token_ == Network.IMD || token_.code.length == 0) {
            revert InvalidAddress();
        }
        token = token_;
        emit TokenSet(token_);
    }
}
