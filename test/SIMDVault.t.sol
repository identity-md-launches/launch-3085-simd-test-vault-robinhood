// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {Network} from "../src/Network.sol";
import {VaultLinked} from "../src/VaultLinked.sol";
import {MockToken, MockIntake, RejectNative, ConsumeNativeGas, ReenterNative} from "./mocks/Mocks.sol";

contract SIMDVaultTest is BaseTest {
    function test_constructorDeploysLinkedContractsOnAnEmptyChain() public {
        vm.etch(Network.INTAKE, "");
        vm.etch(Network.IMD, "");
        vm.etch(Network.FACTORY, "");
        SIMDVault fresh = new SIMDVault();
        assertEq(fresh.holderRewards().vault(), address(fresh));
        assertEq(fresh.jobsVault().vault(), address(fresh));
        assertEq(fresh.simdAirdrop().vault(), address(fresh));
        assertEq(fresh.holderRewards().jobsVault(), address(fresh.jobsVault()));
        assertEq(fresh.holderRewards().simdAirdrop(), address(fresh.simdAirdrop()));
        assertLe(type(SIMDVault).creationCode.length, 49_152);
        assertLe(address(fresh).code.length, 24_576);
        assertLe(address(fresh.holderRewards()).code.length, 24_576);
    }

    function test_launchOnlyDevOncePaysExactLivePriceFromVault() public {
        bytes memory body = bytes('{"onchain":"univ4_hook","objective":"SIMD TEST 2 - DO NOT BUY"}');
        imd.mint(address(vault), 10 ether);
        intake.setPrice(Network.LAUNCH_ACTION, 0.75 ether);
        vm.expectRevert(SIMDVault.OnlyDev.selector);
        vault.launch(body);
        vm.prank(Network.DEV);
        bytes32 id = vault.launch(body);
        MockIntake.Request memory r = intake.getRequest(id);
        assertEq(r.payer, address(vault));
        assertEq(r.action, Network.LAUNCH_ACTION);
        assertEq(r.body, body);
        assertEq(r.callback.target, address(0));
        assertEq(r.callback.selector, bytes4(0));
        assertEq(r.asset, Network.IMD);
        assertEq(r.amount, 0.75 ether);
        assertEq(imd.balanceOf(address(vault)), 9.25 ether);
        assertEq(imd.allowance(address(vault), Network.INTAKE), 0);
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.AlreadyLaunched.selector);
        vault.launch(body);
    }

    function test_failedLaunchDoesNotConsumeOneShotOrLeaveApproval() public {
        imd.mint(address(vault), PRICE);
        intake.setFailure(false, true);
        vm.prank(Network.DEV);
        vm.expectRevert("request unavailable");
        vault.launch("{}");
        assertFalse(vault.launched());
        assertEq(imd.allowance(address(vault), Network.INTAKE), 0);
        intake.setFailure(false, false);
        vm.prank(Network.DEV);
        vault.launch("{}");
        assertTrue(vault.launched());
    }

    function test_launchUnavailablePriceAndInvalidBodiesRevert() public {
        vm.startPrank(Network.DEV);
        vm.expectRevert(SIMDVault.InvalidBody.selector);
        vault.launch("");
        vm.expectRevert(SIMDVault.InvalidBody.selector);
        vault.launch(new bytes(16_385));
        vm.stopPrank();
        intake.setPrice(Network.LAUNCH_ACTION, 0);
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.ActionNotSold.selector);
        vault.launch("{}");
    }

    function test_bindOnlyDevOnceAndInitializesChildrenOnce() public {
        vm.expectRevert(SIMDVault.OnlyDev.selector);
        vault.bindLaunch(LAUNCH, address(token));
        vm.expectRevert(VaultLinked.OnlyVault.selector);
        rewards.setToken(address(token));
        vm.expectRevert(VaultLinked.OnlyVault.selector);
        jobs.setToken(address(token));
        _bind();
        assertEq(vault.token(), address(token));
        assertEq(vault.launchNumber(), LAUNCH);
        assertEq(rewards.token(), address(token));
        assertEq(jobs.token(), address(token));
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.AlreadyBound.selector);
        vault.bindLaunch(LAUNCH, address(token));
        vm.prank(address(vault));
        vm.expectRevert(VaultLinked.TokenAlreadySet.selector);
        rewards.setToken(address(token));
        vm.prank(address(vault));
        vm.expectRevert(VaultLinked.TokenAlreadySet.selector);
        jobs.setToken(address(token));
    }

    function test_bindRejectsOtherRequesterAndNonPoolTokens() public {
        _position(LAUNCH, address(token), Network.IMD, alice);
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.InvalidRequester.selector);
        vault.bindLaunch(LAUNCH, address(token));
        _position(LAUNCH, address(token), Network.IMD, address(vault));
        address unrelated = address(new MockToken(18));
        vm.startPrank(Network.DEV);
        vm.expectRevert(SIMDVault.InvalidToken.selector);
        vault.bindLaunch(LAUNCH, unrelated);
        vm.expectRevert(SIMDVault.InvalidToken.selector);
        vault.bindLaunch(LAUNCH, Network.IMD);
        vm.expectRevert(SIMDVault.InvalidToken.selector);
        vault.bindLaunch(LAUNCH, address(0));
        vm.stopPrank();
        assertFalse(vault.bound());
    }

    function test_distributionRequiresBindingAndAllowsFirstImmediatelyThenExactlySevenDays() public {
        vm.expectRevert(SIMDVault.NotBound.selector);
        vault.distribute();
        vm.warp(0);
        _bind();
        vault.distribute();
        vm.expectRevert(SIMDVault.TooSoon.selector);
        vault.distribute();
        vm.warp(7 days - 1);
        vm.expectRevert(SIMDVault.TooSoon.selector);
        vault.distribute();
        vm.warp(7 days);
        vault.distribute();
        assertEq(factory.claims(), 2);
    }

    function test_distributionSplitsFeesAndExistingFundsBurnsAllTokensAndSendsNative() public {
        _bind();
        imd.mint(address(vault), 600 ether);
        imd.mint(Network.FACTORY, 400 ether);
        token.mint(address(vault), 50 ether);
        token.mint(Network.FACTORY, 25 ether);
        vm.deal(Network.FACTORY, 2 ether);
        vm.deal(address(vault), 1 ether);
        factory.setPayouts(400 ether, 25 ether, 2 ether);
        uint256 beforeEth = Network.MARKETING.balance;
        vm.prank(alice);
        vault.distribute();
        assertEq(imd.balanceOf(address(rewards)), 400 ether - PRICE);
        assertEq(imd.balanceOf(address(jobs)), 257.2 ether);
        // The task deliberately names the same wallet twice; it receives both independently rounded shares.
        assertEq(imd.balanceOf(Network.DEV), 342.8 ether);
        assertEq(imd.balanceOf(Network.INTAKE), PRICE);
        assertEq(imd.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(Network.BURN), 75 ether);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(Network.MARKETING.balance - beforeEth, 3 ether);
        assertEq(address(vault).balance, 0);
        assertEq(rewards.epoch(1).snapshotBlock, block.number);
    }

    function test_failedFeeClaimStillSplitsExistingFunds() public {
        _bind();
        factory.setFails(true);
        imd.mint(address(vault), 10 ether);
        token.mint(address(vault), 3 ether);
        vault.distribute();
        assertEq(imd.balanceOf(address(jobs)), 2.572 ether);
        assertEq(token.balanceOf(Network.BURN), 3 ether);
    }

    function test_feeClaimConsumingGasStillSplits() public {
        _bind();
        factory.setUseAllGas(true);
        imd.mint(address(vault), 10 ether);
        vault.distribute{gas: 6_000_000}();
        assertEq(imd.balanceOf(address(jobs)), 2.572 ether);
    }

    function test_nativeRejectionDoesNotBlockSplitAndCanBeRetriedNextWeek() public {
        _bind();
        imd.mint(address(vault), 10 ether);
        token.mint(address(vault), 3 ether);
        vm.etch(Network.MARKETING, address(new RejectNative()).code);
        vm.deal(Network.FACTORY, 1 ether);
        factory.setPayouts(0, 0, 1 ether);
        vault.distribute();
        assertEq(address(vault).balance, 1 ether);
        assertEq(imd.balanceOf(address(jobs)), 2.572 ether);
        assertEq(token.balanceOf(Network.BURN), 3 ether);
        vm.etch(Network.MARKETING, "");
        _nextWeek();
        vault.distribute();
        assertEq(address(vault).balance, 0);
        assertEq(Network.MARKETING.balance, 1 ether);
    }

    function test_nativeGasGriefCannotBlockSplitOrBurn() public {
        _bind();
        vm.etch(Network.MARKETING, address(new ConsumeNativeGas()).code);
        imd.mint(address(vault), 10 ether);
        token.mint(address(vault), 3 ether);
        vm.deal(address(vault), 1 ether);
        vault.distribute{gas: 6_000_000}();
        assertEq(address(vault).balance, 1 ether);
        assertEq(imd.balanceOf(address(jobs)), 2.572 ether);
        assertEq(token.balanceOf(Network.BURN), 3 ether);
    }

    function test_reentrantFactoryIntakeTokenAndNativeReceiverCannotDoubleDistribute() public {
        _bind();
        imd.mint(address(vault), 10 ether);
        vm.deal(address(vault), 1 ether);
        bytes memory reentry = abi.encodeCall(vault.distribute, ());
        factory.setReentry(address(vault), reentry);
        intake.setReentry(address(vault), reentry);
        imd.setReentry(address(vault), reentry);
        vm.etch(Network.MARKETING, address(new ReenterNative(address(vault))).code);
        vault.distribute();
        assertFalse(factory.reentrySucceeded());
        assertFalse(intake.reentrySucceeded());
        assertFalse(imd.reentrySucceeded());
        assertFalse(ReenterNative(payable(Network.MARKETING)).succeeded());
        assertEq(factory.claims(), 1);
        assertEq(imd.balanceOf(address(jobs)), 2.572 ether);
    }

    function test_smallOracleDepositAndOracleFailuresNeverBlockSplit() public {
        _bind();
        imd.mint(address(vault), 1 ether);
        token.mint(address(vault), 1 ether);
        vault.distribute();
        assertEq(imd.balanceOf(address(rewards)), 0.4 ether);
        assertEq(intake.nonce(), 0);
        assertEq(token.balanceOf(Network.BURN), 1 ether);
        _nextWeek();
        intake.setFailure(true, false);
        imd.mint(address(vault), 10 ether);
        vault.distribute();
        assertEq(imd.balanceOf(address(jobs)), 2.8292 ether);
        assertEq(imd.balanceOf(address(rewards)), 4.4 ether);
        _nextWeek();
        intake.setFailure(false, true);
        imd.mint(address(vault), 10 ether);
        vault.distribute();
        assertEq(imd.balanceOf(address(rewards)), 8.4 ether);
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
    }

    function test_gasExhaustingOracleRequestDoesNotBlockDistribution() public {
        _bind();
        intake.setUseAllGas(true);
        imd.mint(address(vault), 10 ether);
        token.mint(address(vault), 1 ether);
        vault.distribute{gas: 6_000_000}();
        assertEq(imd.balanceOf(address(rewards)), 4 ether);
        assertEq(imd.balanceOf(address(jobs)), 2.572 ether);
        assertEq(token.balanceOf(Network.BURN), 1 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitConservesEveryWeiWithAtMostThreeWeiDust(uint128 amount) public {
        _bind();
        intake.setPrice(Network.ORACLE_ACTION, 0);
        imd.mint(address(vault), amount);
        vault.distribute();
        uint256 holder = imd.balanceOf(address(rewards));
        uint256 jobsBalance = imd.balanceOf(address(jobs));
        uint256 wallets = imd.balanceOf(Network.DEV);
        uint256 dust = imd.balanceOf(address(vault));
        assertEq(holder, uint256(amount) * 4000 / 10000);
        assertEq(jobsBalance, uint256(amount) * 2572 / 10000);
        assertEq(wallets, 2 * (uint256(amount) * 1714 / 10000));
        assertEq(holder + jobsBalance + wallets + dust, amount);
        assertLe(dust, 3);
        _nextWeek();
        vault.distribute();
        assertEq(
            imd.balanceOf(address(rewards)) + imd.balanceOf(address(jobs)) + imd.balanceOf(Network.DEV)
                + imd.balanceOf(address(vault)),
            amount
        );
    }
}
