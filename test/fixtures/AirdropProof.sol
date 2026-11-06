// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Real proof for the task's fixed root, recovered from the successful Robinhood claim
/// tx 0xc07c2b61799054ee0ca36b30cb2b2ddf08899bb589c78f4ab4658705100405ca.
/// Source: https://rpc.mainnet.chain.robinhood.com (eth_getTransactionByHash).
library AirdropProof {
    address internal constant ACCOUNT = 0xdFA1f1F6FEAA04F7874efF0b7754b7FFaEBd8BC0;
    uint256 internal constant WEIGHT = 1000000000000000000000000;

    function proof() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](9);
        p[0] = 0xe4ff57aa457b21c01a60b9fc9dbacd03f0ee8c5e47e9c7010e340f800badbdd3;
        p[1] = 0x4ce74083bff9ed356d28547f9abad9e0d6c9e9454b1fc4be5f7ed4b11c98c38f;
        p[2] = 0x6a16de3c0fc4cc935f7e1cd9038d072869a91ac9e2118f7d05eb009137aa105b;
        p[3] = 0x4cbd54edbc9612c9ec32747b7e463837e828f94d01ea52eb5276c493a9e3d00d;
        p[4] = 0x42a91268b5b004a53115176d4f4b2ba3e2fc97075f705d3f69e383ec1bf1ffab;
        p[5] = 0x901e2383769f3e3c416b74c09866ea4d5e630c51d2d78bfad4ee4e7cfee2f1d1;
        p[6] = 0x6834d6a26962b2430152ececddde513fe368bcc0586c07ba04f2dc5958cb361f;
        p[7] = 0x0f29adf3fac9c81c40c0e0de81e70b0ad316c878daddd71e4095c1cafeb9895c;
        p[8] = 0xda1ea997de088bc6bf962210c197f160b8d4468b393306aad60b05ca40d77b5b;
    }
}
