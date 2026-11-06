// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {JobsVault} from "../src/JobsVault.sol";
import {VaultLinked} from "../src/VaultLinked.sol";
import {Network} from "../src/Network.sol";
import {MockToken, MockIntake} from "./mocks/Mocks.sol";

contract JobsVaultTest is BaseTest {
    function test_unconfiguredAndInsufficientHoldersCannotSpend() public {
        vm.prank(alice);
        vm.expectRevert(VaultLinked.TokenNotSet.selector);
        jobs.requestJob("{}");
        _bind();
        token.mint(alice, 1_000_000 ether - 1);
        imd.mint(address(jobs), 10 ether);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientHolding.selector);
        jobs.requestJob("{}");
        assertEq(imd.balanceOf(address(jobs)), 10 ether);
        token.mint(alice, 1);
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(imd.balanceOf(address(jobs)), 10 ether - PRICE);
    }

    function test_eachWalletGetsOneJobPerRollingTwentyFourHours() public {
        _bind();
        token.mint(alice, 1_000_000 ether);
        token.mint(bob, 1_000_000 ether);
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

    function test_soldOrTransferredHoldingIsCheckedAgain() public {
        _bind();
        token.mint(alice, 1_000_000 ether);
        imd.mint(address(jobs), 10 ether);
        vm.prank(alice);
        jobs.requestJob("{}");
        vm.prank(alice);
        token.transfer(bob, 1_000_000 ether);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(JobsVault.InsufficientHolding.selector);
        jobs.requestJob("{}");
        vm.prank(bob);
        jobs.requestJob("{}");
    }

    function test_failedRequestAndInsufficientIMDDoNotConsumeDailySlot() public {
        _bind();
        token.mint(alice, 1_000_000 ether);
        vm.prank(alice);
        vm.expectRevert();
        jobs.requestJob("{}");
        assertEq(jobs.nextJobAt(alice), 0);
        imd.mint(address(jobs), 10 ether);
        intake.setFailure(false, true);
        vm.prank(alice);
        vm.expectRevert("request unavailable");
        jobs.requestJob("{}");
        assertEq(jobs.nextJobAt(alice), 0);
        assertEq(imd.allowance(address(jobs), Network.INTAKE), 0);
        intake.setFailure(false, false);
        intake.setPrice(Network.JOB_ACTION, 1 ether);
        vm.prank(alice);
        jobs.requestJob("{}");
        assertEq(imd.balanceOf(address(jobs)), 9 ether);
    }

    function test_rejectsEmptyOversizedAndUnavailableAction() public {
        _bind();
        token.mint(alice, 1_000_000 ether);
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

    function test_sixDecimalTokenUsesOneMillionWholeTokens() public {
        MockToken six = new MockToken(6);
        _position(LAUNCH, address(six), Network.IMD, address(vault));
        vm.prank(Network.DEV);
        vault.bindLaunch(LAUNCH, address(six));
        assertEq(jobs.minimumHolding(), 1_000_000e6);
        six.mint(alice, 1_000_000e6);
        imd.mint(address(jobs), PRICE);
        vm.prank(alice);
        jobs.requestJob("{}");
    }

    function test_reentryFromIntakeCannotBuyTwice() public {
        _bind();
        token.mint(alice, 1_000_000 ether);
        token.mint(Network.INTAKE, 1_000_000 ether);
        imd.mint(address(jobs), 10 ether);
        intake.setReentry(address(jobs), abi.encodeCall(jobs.requestJob, (bytes("{}"))));
        vm.prank(alice);
        jobs.requestJob("{}");
        assertFalse(intake.reentrySucceeded());
        assertEq(intake.nonce(), 1);
    }
}
