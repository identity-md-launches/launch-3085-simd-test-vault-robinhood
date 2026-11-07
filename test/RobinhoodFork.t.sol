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
/// @dev The HOOK factory's newest launch is 3076, the previous test launch, which this suite's
/// contracts refuse by design. The flows after binding therefore use position 3077 answered by
/// vm.mockCall with the real 3076 pool key and this vault as requester; the real factory, Intake,
/// IMD and pool token stay in place and the real factory's claimFees is exercised directly.
contract RobinhoodForkTest is Test {
    uint64 constant EXISTING_LAUNCH = 3076;
    uint64 constant NEXT_LAUNCH = 3077;
    SIMDVault vault;
    IERC20 imd = IERC20(Network.IMD);
    IHookFactory factory = IHookFactory(Network.FACTORY);
    ILiveIntake intake = ILiveIntake(Network.INTAKE);
    address poolToken;
    PoolKey existingKey;

    function setUp() public {
        if (block.chainid != 4663 || Network.INTAKE.code.length == 0 || Network.FACTORY.code.length == 0) {
            vm.skip(true);
            return;
        }
        vault = new SIMDVault();
        // Set the harness block explicitly to the fork's L2 height. Do not etch/mock ArbSys.
        vm.roll(vault.holderRewards().snapshotHead());
        (existingKey,,,) = factory.positionOf(EXISTING_LAUNCH);
        poolToken = existingKey.currency0 == Network.IMD ? existingKey.currency1 : existingKey.currency0;
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
        (PoolKey memory none,,, address requester) = factory.positionOf(NEXT_LAUNCH);
        assertEq(requester, address(0), "launch 3077 now exists: bind it directly instead of mocking");
        assertEq(none.currency0, address(0));
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

    function testFork_realFactoryRejectsUnrelatedRequesterAndEveryoneRejectsHistoricalLaunch() public {
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.InvalidRequester.selector);
        vault.bindLaunch(EXISTING_LAUNCH, poolToken);
        SimdAirdrop drop = vault.simdAirdrop();
        vm.expectRevert(SimdAirdrop.InvalidLaunch.selector);
        drop.bind(EXISTING_LAUNCH);
        // Even handed over by its real requester, the previous test launch is refused by the vault.
        (,,, address requester) = factory.positionOf(EXISTING_LAUNCH);
        vm.prank(requester);
        ILiveHookFactory(Network.FACTORY).setRequester(EXISTING_LAUNCH, address(vault));
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.InvalidLaunch.selector);
        vault.bindLaunch(EXISTING_LAUNCH, poolToken);
        assertFalse(vault.bound());
    }

    function testFork_realFactoryClaimFeesPaysItsRecordedRequester() public {
        (,,, address requester) = factory.positionOf(EXISTING_LAUNCH);
        uint256 before = imd.balanceOf(requester);
        // Prove the real claimFees ABI and that anyone may call it; it pays the requester, not the caller.
        vm.prank(makeAddr("anyone"));
        factory.claimFees(EXISTING_LAUNCH);
        assertGe(imd.balanceOf(requester), before);
    }

    function _bindNextLaunchOnFork() private {
        // Local fork only: the next launch number answers with the real 3076 pool key and this vault.
        vm.mockCall(
            Network.FACTORY,
            abi.encodeCall(IHookFactory.positionOf, (NEXT_LAUNCH)),
            abi.encode(existingKey, int24(-60), int24(60), address(vault))
        );
        vm.prank(Network.DEV);
        vault.bindLaunch(NEXT_LAUNCH, poolToken);
    }

    function testFork_distributionPaysRealIntakeOracleWithADeepEnoughWindow() public {
        _bindNextLaunchOnFork();
        deal(Network.IMD, address(vault), 100 ether);
        deal(poolToken, address(vault), 50 ether);
        uint256 beforeWallet = imd.balanceOf(Network.DEV);
        uint256 beforeBurn = IERC20(poolToken).balanceOf(Network.BURN);
        uint256 oraclePrice = intake.priceOf(Network.ORACLE_ACTION, Network.IMD);
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
        assertEq(e.snapshotBlock, rewards.snapshotHead() - rewards.SNAPSHOT_DEPTH());
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
    }

    function testFork_holderJobUsesRealTokenStakeAndRealIntake() public {
        _bindNextLaunchOnFork();
        JobsVault jobs = vault.jobsVault();
        address holder = makeAddr("fork holder");
        uint256 threshold = jobs.minimumHolding();
        assertEq(threshold, 1_000_000 * 10 ** IERC20Metadata(poolToken).decimals());
        deal(poolToken, holder, threshold);
        uint256 price = intake.priceOf(Network.JOB_ACTION, Network.IMD);
        deal(Network.IMD, address(jobs), price);
        bytes memory body = bytes('{"objective":"Research SIMD TEST risks.","template":"research"}');
        vm.prank(holder);
        vm.expectRevert(JobsVault.InsufficientHolding.selector);
        jobs.requestJob(body);
        vm.startPrank(holder);
        IERC20(poolToken).approve(address(jobs), threshold);
        jobs.stake(threshold);
        bytes32 id = jobs.requestJob(body);
        vm.expectRevert(JobsVault.StakeLocked.selector);
        jobs.unstake(threshold);
        vm.stopPrank();
        (address payer, address target,,) = intake.requests(id);
        assertEq(payer, address(vault.jobsVault()));
        assertEq(target, address(0));
        assertEq(imd.balanceOf(address(vault.jobsVault())), 0);
        assertEq(IERC20(poolToken).balanceOf(address(jobs)), threshold);
    }

    function testFork_airdropBindsTheRealTokenRemainderAndRefusesOtherLaunches() public {
        _bindNextLaunchOnFork();
        SimdAirdrop drop = vault.simdAirdrop();
        deal(poolToken, address(drop), drop.TOTAL_WEIGHT());
        vm.expectRevert(SimdAirdrop.InvalidLaunch.selector);
        drop.bind(EXISTING_LAUNCH);
        drop.bind(NEXT_LAUNCH);
        assertEq(drop.token(), poolToken);
        assertEq(drop.startBalance(), drop.TOTAL_WEIGHT());
        assertEq(drop.claimEnd(), block.timestamp + 30 days);
    }
}
