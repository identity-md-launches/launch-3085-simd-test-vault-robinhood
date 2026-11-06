// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed Robinhood Chain dependencies and beneficiaries for SIMD TEST 2.
library Network {
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant FACTORY = 0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645;
    address internal constant DEV = 0xdFA1f1F6FEAA04F7874efF0b7754b7FFaEBd8BC0;
    address internal constant MARKETING = 0xdFA1f1F6FEAA04F7874efF0b7754b7FFaEBd8BC0;
    address internal constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant LAUNCH_ACTION = bytes32("launch.open@launch-1");
    bytes32 internal constant ORACLE_ACTION = bytes32("oracle.request@oracle-1");
    bytes32 internal constant JOB_ACTION = bytes32("job.open@job-1");
    uint256 internal constant MAX_BODY_BYTES = 16_384;
}
