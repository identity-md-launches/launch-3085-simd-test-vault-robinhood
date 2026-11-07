// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {JobsVault} from "../src/JobsVault.sol";
import {VaultLinked} from "../src/VaultLinked.sol";
import {Network} from "../src/Network.sol";
import {MockToken, MockIntake} from "./mocks/Mocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev One wallet's worth of tokens passed along a chain: each hop tries to buy a job, then hands on.
contract Hop {
    function run(JobsVault jv, IERC20 t, address next) external returns (bool ok) {
        t.approve(address(jv), type(uint256).max);
        try jv.stake(t.balanceOf(address(this))) {} catch {}
        try jv.requestJob("attacker job") {
            ok = true;
        } catch {}
        try jv.unstake(jv.stakeOf(address(this))) {} catch {}
        t.transfer(next, t.balanceOf(address(this)));
    }
}

contract JobsVaultTest is BaseTest {
    uint256 internal constant HOLDING = 1_000_000 ether;

    function _stake(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(jobs), amount);
        jobs.stake(amount);
        vm.stopPrank();
    }

    function test_unconfiguredInsufficientAndSpotHoldersCannotSpend() public {
        vm.prank(alice);
        vm.expectRevert(VaultLinked.TokenNotSet.selector);
        jobs.requestJob("{}");
        vm.prank(alice);
        vm.expectRevert(VaultLinked.TokenNotSet.selector);
        jobs.stake(1);
        _bind();
        imd.mint(address(jobs), 10 ether);
        // A spot balance, however large, is not eligibility: it can be lent within one transaction.
        token.mint(alice, 10 * HOLDING);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientHolding.selector);
        jobs.requestJob("{}");
        _stake(alice, HOLDING - 1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientHolding.selector);
        jobs.requestJob("{}");
        assertEq(imd.balanceOf(address(jobs)), 10 ether);
        _stake(alice, 1);
        assertEq(jobs.stakeOf(alice), HOLDING);
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(imd.balanceOf(address(jobs)), 10 ether - PRICE);
    }

    function test_eachStakedWalletGetsOneJobPerRollingTwentyFourHours() public {
        _bind();
        _stake(alice, HOLDING);
        _stake(bob, HOLDING);
        imd.mint(address(jobs), 10 ether);
        uint256 start = block.timestamp;
        bytes memory body = bytes('{"objective":"Research SIMD TEST risks.","template":"research"}');
        vm.prank(alice);
        bytes32 id = jobs.requestJob(body);
        MockIntake.Request memory r = intake.getRequest(id);
        assertEq(r.payer, address(jobs));
        assertEq(r.action, Network.JOB_ACTION);
        assertEq(r.body, body);
        assertEq(r.callback.target, address(0));
        assertEq(r.amount, PRICE);
        assertEq(imd.allowance(address(jobs), Network.INTAKE), 0);
        vm.prank(bob);
        jobs.requestJob(body);
        vm.prank(alice);
        vm.expectRevert(JobsVault.DailyLimit.selector);
        jobs.requestJob(body);
        vm.warp(start + 1 days - 1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.DailyLimit.selector);
        jobs.requestJob(body);
        vm.warp(start + 1 days);
        vm.prank(alice);
        jobs.requestJob(body);
        assertEq(intake.nonce(), 3);
    }

    function test_stakeThatBoughtAJobIsLockedForTheIntervalThenReturnedOnlyToItsOwner() public {
        _bind();
        _stake(alice, HOLDING + 5);
        imd.mint(address(jobs), 10 ether);
        // Before any job the stake is free to leave.
        vm.prank(alice);
        jobs.unstake(5);
        assertEq(token.balanceOf(alice), 5);
        uint256 start = block.timestamp;
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(jobs.lockedUntil(alice), start + 1 days);
        vm.prank(alice);
        vm.expectRevert(JobsVault.StakeLocked.selector);
        jobs.unstake(1);
        vm.warp(start + 1 days - 1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.StakeLocked.selector);
        jobs.unstake(1);
        vm.warp(start + 1 days);
        vm.prank(bob);
        vm.expectRevert(JobsVault.InsufficientStake.selector);
        jobs.unstake(1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientStake.selector);
        jobs.unstake(HOLDING + 1);
        vm.prank(alice);
        vm.expectRevert(JobsVault.ZeroAmount.selector);
        jobs.unstake(0);
        vm.prank(alice);
        jobs.unstake(HOLDING);
        assertEq(token.balanceOf(alice), HOLDING + 5);
        assertEq(jobs.stakeOf(alice), 0);
        assertEq(token.balanceOf(address(jobs)), 0);
        // Without the stake the wallet is no longer eligible; the next holder of the tokens is.
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientHolding.selector);
        jobs.requestJob("{}");
        vm.prank(alice);
        token.transfer(bob, HOLDING);
        vm.startPrank(bob);
        token.approve(address(jobs), HOLDING);
        jobs.stake(HOLDING);
        jobs.requestJob("{}");
        vm.stopPrank();
        assertEq(intake.nonce(), 2);
    }

    function test_oneHoldingPassedBetweenWalletsBuysAtMostOneJobPerDay() public {
        _bind();
        imd.mint(address(jobs), 10 ether);
        Hop[] memory hops = new Hop[](10);
        for (uint256 i; i < 10; ++i) {
            hops[i] = new Hop();
        }
        token.mint(address(hops[0]), HOLDING);
        uint256 paid;
        for (uint256 i; i < 10; ++i) {
            address next = i + 1 < 10 ? address(hops[i + 1]) : alice;
            if (hops[i].run(jobs, token, next)) ++paid;
        }
        // The first hop's stake bought one job and is now locked there; nothing reached the others.
        assertEq(paid, 1);
        assertEq(imd.balanceOf(address(jobs)), 10 ether - PRICE);
        assertEq(jobs.stakeOf(address(hops[0])), HOLDING);
        assertEq(token.balanceOf(alice), 0);
        // A day later the same holding buys exactly one more job and is locked again for a day.
        vm.warp(block.timestamp + 1 days);
        assertTrue(hops[0].run(jobs, token, address(hops[1])));
        assertEq(imd.balanceOf(address(jobs)), 10 ether - 2 * PRICE);
        assertEq(jobs.stakeOf(address(hops[0])), HOLDING);
        assertEq(token.balanceOf(address(hops[1])), 0);
        assertEq(jobs.lockedUntil(address(hops[0])), vm.getBlockTimestamp() + 1 days);
    }

    function test_failedRequestAndInsufficientIMDDoNotConsumeDailySlotOrLockStake() public {
        _bind();
        _stake(alice, HOLDING);
        vm.prank(alice);
        vm.expectRevert();
        jobs.requestJob("{}");
        assertEq(jobs.nextJobAt(alice), 0);
        assertEq(jobs.lockedUntil(alice), 0);
        imd.mint(address(jobs), 10 ether);
        intake.setFailure(false, true);
        vm.prank(alice);
        vm.expectRevert("request unavailable");
        jobs.requestJob("{}");
        assertEq(jobs.nextJobAt(alice), 0);
        assertEq(jobs.lockedUntil(alice), 0);
        assertEq(imd.allowance(address(jobs), Network.INTAKE), 0);
        intake.setFailure(false, false);
        intake.setPrice(Network.JOB_ACTION, 1 ether);
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(imd.balanceOf(address(jobs)), 9 ether);
    }

    function test_rejectsEmptyOversizedAndUnavailableAction() public {
        _bind();
        _stake(alice, HOLDING);
        vm.startPrank(alice);
        vm.expectRevert(JobsVault.InvalidBody.selector);
        jobs.requestJob("");
        vm.expectRevert(JobsVault.InvalidBody.selector);
        jobs.requestJob(new bytes(16_385));
        vm.stopPrank();
        intake.setPrice(Network.JOB_ACTION, 0);
        vm.prank(alice);
        vm.expectRevert(JobsVault.ActionNotSold.selector);
        jobs.requestJob("{}");
    }

    function test_stakeCountsOnlyTokensReceivedAndRejectsZero() public {
        _bind();
        vm.prank(alice);
        vm.expectRevert(JobsVault.ZeroAmount.selector);
        jobs.stake(0);
        token.mint(alice, 3);
        vm.startPrank(alice);
        token.approve(address(jobs), 3);
        jobs.stake(1);
        jobs.stake(2);
        vm.stopPrank();
        assertEq(jobs.stakeOf(alice), 3);
        assertEq(token.balanceOf(address(jobs)), 3);
        // The vault's IMD never leaves through staking paths.
        imd.mint(address(jobs), 1 ether);
        vm.prank(alice);
        jobs.unstake(3);
        assertEq(imd.balanceOf(address(jobs)), 1 ether);
    }

    function test_sixDecimalTokenUsesOneMillionWholeTokens() public {
        MockToken six = new MockToken(6);
        _position(LAUNCH, address(six), Network.IMD, address(vault));
        vm.prank(Network.DEV);
        vault.bindLaunch(LAUNCH, address(six));
        assertEq(jobs.minimumHolding(), 1_000_000e6);
        six.mint(alice, 1_000_000e6);
        imd.mint(address(jobs), PRICE);
        vm.startPrank(alice);
        six.approve(address(jobs), 1_000_000e6);
        jobs.stake(1_000_000e6);
        jobs.requestJob("{}");
        vm.stopPrank();
    }

    function test_reentryFromIntakeCannotBuyTwice() public {
        _bind();
        _stake(alice, HOLDING);
        _stake(Network.INTAKE, HOLDING);
        imd.mint(address(jobs), 10 ether);
        intake.setReentry(address(jobs), abi.encodeCall(jobs.requestJob, (bytes("{}"))));
        vm.prank(alice);
        jobs.requestJob("{}");
        assertFalse(intake.reentrySucceeded());
        assertEq(intake.nonce(), 1);
    }
}
