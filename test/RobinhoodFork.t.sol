// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {SimdAirdrop} from "../src/SimdAirdrop.sol";
import {JobsVault} from "../src/JobsVault.sol";
import {Network} from "../src/Network.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";
import {IHookFactory, PoolKey} from "../src/interfaces/IHookFactory.sol";

interface ILiveIntake is IIntake {
    function requests(bytes32 id)
        external
        view
        returns (address payer, address target, bytes4 selector, bool completed);
}

interface ILiveHookFactory is IHookFactory {
    function setRequester(uint64 launchNumber, address next) external;
}

/// @notice Run with forge test --match-contract RobinhoodForkTest --fork-url <Robinhood RPC>
/// Add --fork-block-number when using an archive endpoint. No environment reads or network in the offline run.
contract RobinhoodForkTest is Test {
    uint64 constant EXISTING_LAUNCH = 3076;
    SIMDVault vault;
    IERC20 imd = IERC20(Network.IMD);
    IHookFactory factory = IHookFactory(Network.FACTORY);
    ILiveIntake intake = ILiveIntake(Network.INTAKE);
    address poolToken;

    function setUp() public {
        if (block.chainid != 4663 || Network.INTAKE.code.length == 0 || Network.FACTORY.code.length == 0) {
            vm.skip(true);
            return;
        }
        vault = new SIMDVault();
        // Set the harness block explicitly to the fork's L2 height. Do not etch/mock ArbSys.
        vm.roll(vault.holderRewards().snapshotHead());
        (PoolKey memory key,,,) = factory.positionOf(EXISTING_LAUNCH);
        poolToken = key.currency0 == Network.IMD ? key.currency1 : key.currency0;
    }

    function testFork_fixedContractsAreRealAndABICompatible() public {
        emit log_named_uint("Robinhood fork block", block.number);
        assertEq(vault.holderRewards().snapshotHead(), block.number);
        assertEq(block.chainid, 4663);
        assertEq(IERC20Metadata(Network.IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(Network.IMD).decimals(), 18);
        assertGt(intake.priceOf(Network.LAUNCH_ACTION, Network.IMD), 0);
        assertGt(intake.priceOf(Network.ORACLE_ACTION, Network.IMD), 0);
        assertGt(intake.priceOf(Network.JOB_ACTION, Network.IMD), 0);
        assertGt(factory.poolManager().code.length, 0);
        assertGt(poolToken.code.length, 0);
    }

    function testFork_realIntakeRecordsVaultAsLaunchRequesterAndPullsExactPrice() public {
        uint256 price = intake.priceOf(Network.LAUNCH_ACTION, Network.IMD);
        deal(Network.IMD, address(vault), price);
        bytes memory body = bytes(
            '{"objective":"SIMD TEST 2 - DO NOT BUY integration test","onchain":"univ4_hook","chainId":4663}'
        );
        vm.prank(Network.DEV);
        bytes32 id = vault.launch(body);
        (address payer, address target, bytes4 selector, bool completed) = intake.requests(id);
        assertEq(payer, address(vault));
        assertEq(target, address(0));
        assertEq(selector, bytes4(0));
        assertFalse(completed);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(imd.allowance(address(vault), Network.INTAKE), 0);
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.AlreadyLaunched.selector);
        vault.launch(body);
    }

    function testFork_realFactoryRejectsUnrelatedRequesterAndAirdropRejectsHistoricalLaunch() public {
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.InvalidRequester.selector);
        vault.bindLaunch(EXISTING_LAUNCH, poolToken);
        SimdAirdrop drop = vault.simdAirdrop();
        vm.expectRevert(SimdAirdrop.InvalidLaunch.selector);
        drop.bind(EXISTING_LAUNCH);
    }

    function _bindExistingPositionOnFork() private {
        // Local fork only: the real factory's existing requester hands its position to the new test vault.
        // No factory/token/Intake code is replaced and no transaction is broadcast.
        (,,, address requester) = factory.positionOf(EXISTING_LAUNCH);
        vm.prank(requester);
        ILiveHookFactory(Network.FACTORY).setRequester(EXISTING_LAUNCH, address(vault));
        vm.prank(Network.DEV);
        vault.bindLaunch(EXISTING_LAUNCH, poolToken);
    }

    function testFork_realFactoryClaimsAndDistributionPaysRealIntakeOracle() public {
        _bindExistingPositionOnFork();
        // Prove claimFees itself succeeds, rather than merely observing the vault's try/catch.
        factory.claimFees(EXISTING_LAUNCH);
        deal(Network.IMD, address(vault), 100 ether);
        deal(poolToken, address(vault), 50 ether);
        uint256 beforeWallet = imd.balanceOf(Network.DEV);
        uint256 beforeBurn = IERC20(poolToken).balanceOf(Network.BURN);
        uint256 oraclePrice = intake.priceOf(Network.ORACLE_ACTION, Network.IMD);
        vm.recordLogs();
        vault.distribute();
        HolderRewards rewards = vault.holderRewards();
        HolderRewards.Epoch memory e = rewards.epoch(1);
        assertTrue(e.requestId != bytes32(0), "real oracle request failed");
        (address payer, address target, bytes4 selector,) = intake.requests(e.requestId);
        assertEq(payer, address(rewards));
        assertEq(target, address(rewards));
        assertEq(selector, rewards.onOracleResult.selector);
        assertEq(imd.balanceOf(address(rewards)), 40 ether - oraclePrice);
        assertEq(imd.balanceOf(address(vault.jobsVault())), 25.72 ether);
        assertEq(imd.balanceOf(Network.DEV) - beforeWallet, 34.28 ether);
        assertEq(IERC20(poolToken).balanceOf(Network.BURN) - beforeBurn, 50 ether);
        assertEq(e.snapshotBlock, rewards.snapshotHead());
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
    }

    function testFork_holderJobUsesRealTokenThresholdAndRealIntake() public {
        _bindExistingPositionOnFork();
        JobsVault jobs = vault.jobsVault();
        address holder = makeAddr("fork holder");
        uint256 threshold = jobs.minimumHolding();
        deal(poolToken, holder, threshold);
        uint256 price = intake.priceOf(Network.JOB_ACTION, Network.IMD);
        deal(Network.IMD, address(jobs), price);
        vm.prank(holder);
        bytes32 id = jobs.requestJob(bytes('{"objective":"Research SIMD TEST risks.","template":"research"}'));
        (address payer, address target,,) = intake.requests(id);
        assertEq(payer, address(vault.jobsVault()));
        assertEq(target, address(0));
        assertEq(imd.balanceOf(address(vault.jobsVault())), 0);
    }
}
