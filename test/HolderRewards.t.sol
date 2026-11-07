// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {VaultLinked} from "../src/VaultLinked.sol";
import {Network} from "../src/Network.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {MockIntake} from "./mocks/Mocks.sol";

contract HolderRewardsTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _bind();
    }

    function test_depositPinsSnapshotBudgetExclusionsAndCanonicalBody() public {
        vm.roll(12345);
        uint256 id = _deposit(100 ether);
        HolderRewards.Epoch memory e = rewards.epoch(id);
        // The window closes SNAPSHOT_DEPTH blocks behind the asking block: deep enough for the plane.
        assertEq(rewards.SNAPSHOT_DEPTH(), 8);
        assertEq(e.snapshotBlock, 12345 - 8);
        assertEq(e.pot, 99.5 ether);
        assertEq(rewards.reserved(), 99.5 ether);
        MockIntake.Request memory r = intake.getRequest(e.requestId);
        assertEq(r.payer, address(rewards));
        assertEq(r.action, Network.ORACLE_ACTION);
        assertEq(r.callback.target, address(rewards));
        assertEq(r.callback.selector, rewards.onOracleResult.selector);
        bytes memory encodedBody = rewards.oracleBody(id);
        assertEq(r.bodyHash, keccak256(encodedBody));
        assertEq(r.amount, PRICE);
        string memory body = string(encodedBody);
        assertEq(vm.parseJsonUint(body, ".window.fromBlock"), 12345 - 8);
        assertEq(vm.parseJsonUint(body, ".window.toBlock"), 12345 - 8);
        assertLe(vm.parseJsonUint(body, ".window.toBlock") + 5, rewards.snapshotHead());
        // Stakes held by the jobs vault are credited to their stakers, so staking costs no rewards.
        assertTrue(
            vm.contains(
                vm.parseJsonString(body, ".definitions.holders"), vm.toLowercase(vm.toString(address(jobs)))
            )
        );
        assertEq(vm.parseJsonUint(body, ".chainId"), 4663);
        assertEq(vm.parseJsonString(body, ".answerType"), "bytes32");
        assertEq(vm.parseJsonUint(body, ".panelSize"), 30);
        assertEq(vm.parseJsonUint(body, ".quorum"), 20);
        assertLt(bytes(vm.parseJsonString(body, ".question")).length, 2001);
        string[5] memory keys = ["allocation", "exclusions", "holders", "leaves", "tree"];
        for (uint256 i; i < keys.length; ++i) {
            assertLe(bytes(vm.parseJsonString(body, string.concat(".definitions.", keys[i]))).length, 512);
        }
        assertLt(encodedBody.length, 16_385);
        assertTrue(e.questionHash != bytes32(0));
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
    }

    function test_depositAndSubmitAreRestrictedAndNoBalanceIsDoubleCounted() public {
        vm.expectRevert(VaultLinked.OnlyVault.selector);
        rewards.notifyDeposit();
        vm.expectRevert(HolderRewards.OnlySelf.selector);
        rewards.submitOracle(1);
        uint256 id = _deposit(10 ether);
        vm.prank(address(vault));
        rewards.notifyDeposit();
        assertEq(rewards.currentEpoch(), id);
        assertEq(rewards.reserved(), 9.5 ether);
    }

    function test_tinyPotsCarryForwardWithoutSpendingAllFundsOnOracle() public {
        uint256 first = _deposit(0.2 ether);
        assertEq(intake.nonce(), 0);
        uint256 second = _deposit(0.3 ether);
        assertEq(intake.nonce(), 0);
        assertTrue(rewards.epoch(first).closed);
        assertEq(rewards.epoch(second).pot, PRICE);
        uint256 third = _deposit(1 ether);
        assertEq(intake.nonce(), 1);
        assertTrue(rewards.epoch(second).closed);
        assertEq(rewards.epoch(third).pot, 1 ether);
        assertEq(rewards.reserved(), 1 ether);
        assertEq(imd.balanceOf(address(rewards)), 1 ether);
    }

    function test_failedSynchronousOracleRequestRetriesAfterOneDay() public {
        intake.setFailure(false, true);
        uint256 id = _deposit(10 ether);
        uint256 start = block.timestamp;
        assertEq(rewards.epoch(id).pot, 10 ether);
        assertEq(rewards.reserved(), 10 ether);
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
        vm.expectRevert(HolderRewards.TooSoon.selector);
        rewards.retryOracle(id);
        vm.warp(start + 1 days - 1);
        vm.expectRevert(HolderRewards.TooSoon.selector);
        rewards.retryOracle(id);
        vm.warp(start + 1 days);
        intake.setFailure(false, false);
        vm.prank(bob);
        rewards.retryOracle(id);
        assertEq(rewards.epoch(id).pot, 9.5 ether);
        assertEq(intake.nonce(), 1);
        assertEq(rewards.epoch(id).snapshotBlock, 10_000 - 8);
    }

    function test_failedRetryKeepsThePendingRequestAndItsAnswerIsStillAccepted() public {
        uint256 id = _deposit(10 ether);
        HolderRewards.Epoch memory before = rewards.epoch(id);
        OracleAttestation.Attestation memory a = _attestation(id, _leaf(alice, 9.5 ether));
        bytes memory sig = _signature(a);
        vm.warp(block.timestamp + 1 days);
        intake.setFailure(false, true);
        vm.prank(bob);
        rewards.retryOracle(id);
        HolderRewards.Epoch memory after_ = rewards.epoch(id);
        assertEq(after_.requestId, before.requestId, "pending request dropped by a failed retry");
        assertEq(after_.questionHash, before.questionHash);
        assertEq(after_.pot, before.pot);
        assertEq(after_.askedAt, before.askedAt);
        assertEq(rewards.requestEpoch(before.requestId), id);
        assertEq(rewards.reserved(), 9.5 ether);
        // The honest answer to the still-live request, issued before the failed retry, is accepted.
        vm.prank(Network.INTAKE);
        rewards.onOracleResult(before.requestId, a, sig);
        assertEq(rewards.epoch(id).root, _leaf(alice, 9.5 ether));
        vm.prank(alice);
        rewards.claim(id, 9.5 ether, new bytes32[](0));
        assertEq(imd.balanceOf(alice), 9.5 ether);
    }

    function test_retryAtPriceBoundaryKeepsTheLastBoughtRequest() public {
        // 1.4 IMD: pot 0.9 after the first ask; retry -> pot 0.4; price 0.5 >= 0.4 blocks a third ask.
        uint256 start = block.timestamp;
        uint256 id = _deposit(1.4 ether);
        vm.warp(start + 1 days);
        rewards.retryOracle(id);
        bytes32 requestB = rewards.epoch(id).requestId;
        assertEq(rewards.epoch(id).pot, 0.4 ether);
        vm.warp(start + 2 days);
        vm.prank(bob);
        rewards.retryOracle(id);
        assertEq(rewards.epoch(id).requestId, requestB, "request B dropped although nothing replaced it");
        assertEq(rewards.requestEpoch(requestB), id);
        assertEq(intake.nonce(), 2);
        _answer(id, _leaf(alice, 0.4 ether));
        vm.prank(alice);
        rewards.claim(id, 0.4 ether, new bytes32[](0));
        // The epoch keeps its request, so the next deposit does not carry its pot elsewhere.
        uint256 next = _deposit(10 ether);
        assertEq(rewards.epoch(next).pot, 9.5 ether);
        assertFalse(rewards.epoch(id).closed);
    }

    function test_unansweredOracleRetriesFromItsOwnPotAndInvalidatesOldId() public {
        uint256 id = _deposit(10 ether);
        HolderRewards.Epoch memory first = rewards.epoch(id);
        OracleAttestation.Attestation memory oldAnswer = _attestation(id, _leaf(alice, 1 ether));
        bytes memory oldSignature = _signature(oldAnswer);
        _deposit(30 ether);
        uint256 otherPot = rewards.epoch(2).pot;
        vm.warp(block.timestamp + 1 days);
        rewards.retryOracle(id);
        HolderRewards.Epoch memory second = rewards.epoch(id);
        assertEq(second.pot, 9 ether);
        assertEq(rewards.epoch(2).pot, otherPot);
        assertTrue(first.requestId != second.requestId);
        assertTrue(first.questionHash != second.questionHash);
        assertEq(rewards.requestEpoch(first.requestId), 0);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.UnknownRequest.selector);
        rewards.onOracleResult(first.requestId, oldAnswer, oldSignature);
        _answer(id, _leaf(alice, 9 ether));
        vm.prank(alice);
        rewards.claim(id, 9 ether, new bytes32[](0));
        assertEq(imd.balanceOf(address(rewards)), otherPot);
        assertEq(rewards.reserved(), otherPot);
    }

    function test_onlyIntakeAndCurrentKnownRequestCanAnswer() public {
        uint256 id = _deposit(10 ether);
        OracleAttestation.Attestation memory a = _attestation(id, _leaf(alice, 1 ether));
        bytes memory sig = _signature(a);
        bytes32 rid = rewards.epoch(id).requestId;
        vm.expectRevert(HolderRewards.OnlyIntake.selector);
        rewards.onOracleResult(rid, a, sig);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.UnknownRequest.selector);
        rewards.onOracleResult(keccak256("unknown"), a, sig);
        vm.prank(Network.INTAKE);
        rewards.onOracleResult(rid, a, sig);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.UnknownRequest.selector);
        rewards.onOracleResult(rid, a, sig);
        vm.expectRevert(HolderRewards.AlreadyAnswered.selector);
        rewards.retryOracle(id);
    }

    function test_wrongQuestionChainWindowPanelOrAnswerShapeIsRejected() public {
        uint256 id = _deposit(10 ether);
        bytes32 rid = rewards.epoch(id).requestId;
        for (uint256 i; i < 10; ++i) {
            OracleAttestation.Attestation memory a = _attestation(id, _leaf(alice, 1 ether));
            if (i == 0) a.questionHash = keccak256("another question");
            if (i == 1) a.chainId = 1;
            if (i == 2) a.toBlock += 1;
            if (i == 3) a.fromBlock -= 1;
            if (i == 4) a.panelSize = 29;
            if (i == 5) a.quorum = 19;
            if (i == 6) a.agreed = 19;
            if (i == 7) a.agreed = 31;
            if (i == 8) a.answer = abi.encode(uint256(1), uint256(2));
            if (i == 9) a.expiresAt = a.issuedAt - 1;
            bytes memory sig = _signature(a);
            vm.prank(Network.INTAKE);
            vm.expectRevert(
                i == 0 ? HolderRewards.WrongQuestion.selector : HolderRewards.InvalidAttestation.selector
            );
            rewards.onOracleResult(rid, a, sig);
        }
        assertEq(rewards.epoch(id).root, bytes32(0));
    }

    function test_expiredFutureTamperedAndWrongTypeAttestationsRejected() public {
        uint256 id = _deposit(10 ether);
        bytes32 rid = rewards.epoch(id).requestId;
        OracleAttestation.Attestation memory a = _attestation(id, _leaf(alice, 1 ether));
        a.issuedAt -= 1 days;
        a.expiresAt = uint64(block.timestamp - 1);
        bytes memory sig = _signature(a);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.InvalidAttestation.selector);
        rewards.onOracleResult(rid, a, sig);
        a = _attestation(id, _leaf(alice, 1 ether));
        a.expiresAt = uint64(block.timestamp);
        sig = _signature(a);
        vm.warp(block.timestamp + 1);
        vm.prank(Network.INTAKE);
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt)
        );
        rewards.onOracleResult(rid, a, sig);
        a = _attestation(id, _leaf(alice, 1 ether));
        a.issuedAt += 301;
        sig = _signature(a);
        vm.prank(Network.INTAKE);
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt)
        );
        rewards.onOracleResult(rid, a, sig);
        a = _attestation(id, _leaf(alice, 1 ether));
        sig = _signature(a);
        a.answer = abi.encode(_leaf(bob, 1 ether));
        vm.prank(Network.INTAKE);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        rewards.onOracleResult(rid, a, sig);
        a = _attestation(id, _leaf(alice, 1 ether));
        a.answerType = 3;
        sig = _signature(a);
        vm.prank(Network.INTAKE);
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(2), uint8(3))
        );
        rewards.onOracleResult(rid, a, sig);
        a = _attestation(id, bytes32(0));
        sig = _signature(a);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.InvalidAttestation.selector);
        rewards.onOracleResult(rid, a, sig);
    }

    function test_answerToOtherEpochCannotBePairedWithThisRequest() public {
        uint256 first = _deposit(10 ether);
        uint256 second = _deposit(10 ether);
        OracleAttestation.Attestation memory a = _attestation(second, _leaf(alice, 1 ether));
        bytes memory sig = _signature(a);
        bytes32 rid = rewards.epoch(first).requestId;
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.WrongQuestion.selector);
        rewards.onOracleResult(rid, a, sig);
    }

    function test_validProRataClaimsIgnoreBalancesAtClaimTimeAndRejectDoubleOrBadProof() public {
        token.mint(alice, 75 ether);
        token.mint(bob, 25 ether);
        uint256 id = _deposit(100 ether + PRICE);
        _answer(id, _pair(_leaf(alice, 75 ether), _leaf(bob, 25 ether)));
        // Snapshot entitlements do not follow tokens purchased after the deposit.
        vm.prank(alice);
        token.transfer(bob, 75 ether);
        vm.prank(bob);
        vm.expectRevert(HolderRewards.InvalidProof.selector);
        rewards.claim(id, 75 ether, _proof(_leaf(bob, 25 ether)));
        vm.prank(alice);
        rewards.claim(id, 75 ether, _proof(_leaf(bob, 25 ether)));
        vm.prank(alice);
        vm.expectRevert(HolderRewards.AlreadyClaimed.selector);
        rewards.claim(id, 75 ether, _proof(_leaf(bob, 25 ether)));
        vm.prank(bob);
        rewards.claim(id, 25 ether, _proof(_leaf(alice, 75 ether)));
        assertEq(imd.balanceOf(alice), 75 ether);
        assertEq(imd.balanceOf(bob), 25 ether);
        assertEq(imd.balanceOf(address(rewards)), 0);
        assertEq(rewards.reserved(), 0);
        assertEq(rewards.epoch(id).claimed, 100 ether);
    }

    function test_evenValidOversizedMerkleLeavesCannotSpendAnotherEpochsPot() public {
        uint256 id = _deposit(10 ether + PRICE);
        _deposit(100 ether);
        // Deliberately malicious but correctly signed root; the on-chain budget still contains it.
        _answer(id, _pair(_leaf(alice, 7 ether), _leaf(bob, 7 ether)));
        vm.prank(alice);
        rewards.claim(id, 7 ether, _proof(_leaf(bob, 7 ether)));
        vm.prank(bob);
        vm.expectRevert(HolderRewards.PotExceeded.selector);
        rewards.claim(id, 7 ether, _proof(_leaf(alice, 7 ether)));
        assertEq(rewards.epoch(id).claimed, 7 ether);
        assertEq(imd.balanceOf(address(rewards)), 102.5 ether);
    }

    function test_claimBeforeRootOrFromUnlistedWalletPaysNothing() public {
        uint256 id = _deposit(10 ether);
        vm.prank(alice);
        vm.expectRevert(HolderRewards.RootNotReady.selector);
        rewards.claim(id, 1 ether, new bytes32[](0));
        _answer(id, _leaf(alice, 9.5 ether));
        vm.prank(bob);
        vm.expectRevert(HolderRewards.InvalidProof.selector);
        rewards.claim(id, 9.5 ether, new bytes32[](0));
        assertEq(imd.balanceOf(bob), 0);
    }

    function test_rolloverMovesExactlyPotMinusClaimedAndNeverMovesOtherEpochFunds() public {
        uint256 first = _deposit(10 ether + PRICE);
        uint256 start = rewards.epoch(first).openedAt;
        _answer(first, _pair(_leaf(alice, 3 ether), _leaf(bob, 7 ether)));
        vm.prank(alice);
        rewards.claim(first, 3 ether, _proof(_leaf(bob, 7 ether)));
        _nextWeek();
        uint256 current = _deposit(20 ether + PRICE);
        uint256 targetPot = rewards.epoch(current).pot;
        vm.warp(start + 28 days - 1);
        vm.expectRevert(HolderRewards.TooSoon.selector);
        rewards.rollover(first);
        vm.warp(start + 28 days);
        vm.prank(bob);
        vm.expectRevert(HolderRewards.EpochClosed.selector);
        rewards.claim(first, 7 ether, _proof(_leaf(alice, 3 ether)));
        uint256 beforeBalance = imd.balanceOf(address(rewards));
        vm.prank(bob);
        rewards.rollover(first);
        assertEq(rewards.epoch(current).pot, targetPot + 7 ether);
        assertTrue(rewards.epoch(first).closed);
        assertEq(rewards.epoch(current).unallocated, 7 ether);
        assertEq(imd.balanceOf(address(rewards)), beforeBalance);
        assertEq(rewards.reserved(), beforeBalance);
        vm.expectRevert(HolderRewards.EpochClosed.selector);
        rewards.rollover(first);
        uint256 next = _deposit(1 ether + PRICE);
        assertEq(rewards.epoch(next).pot, 8 ether);
        assertEq(rewards.epoch(current).pot, targetPot);
        _answer(next, _leaf(alice, 8 ether));
        vm.prank(alice);
        rewards.claim(next, 8 ether, new bytes32[](0));
        assertEq(rewards.reserved(), targetPot);
    }

    function test_rolloverOfLatestCreatesFreshEpochWithExactRemainderAndPermissionlessFirstAsk() public {
        uint256 id = _deposit(10 ether);
        uint256 pot = rewards.epoch(id).pot;
        vm.warp(block.timestamp + 28 days);
        vm.roll(block.number + 100);
        rewards.rollover(id);
        uint256 next = rewards.currentEpoch();
        assertEq(next, id + 1);
        assertEq(rewards.epoch(next).pot, pot);
        assertEq(rewards.epoch(next).snapshotBlock, vm.getBlockNumber() - 8);
        assertEq(rewards.reserved(), pot);
        vm.prank(alice);
        rewards.retryOracle(next);
        assertEq(rewards.epoch(next).pot, pot - PRICE);
        _answer(next, _leaf(alice, pot - PRICE));
        vm.prank(alice);
        rewards.claim(next, pot - PRICE, new bytes32[](0));
        assertEq(rewards.reserved(), 0);
    }

    function test_lateCallbackAndRetryCannotReopenExpiredEpoch() public {
        uint256 id = _deposit(10 ether);
        OracleAttestation.Attestation memory a = _attestation(id, _leaf(alice, 1 ether));
        bytes memory sig = _signature(a);
        bytes32 rid = rewards.epoch(id).requestId;
        vm.warp(block.timestamp + 28 days);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.EpochClosed.selector);
        rewards.onOracleResult(rid, a, sig);
        vm.expectRevert(HolderRewards.EpochClosed.selector);
        rewards.retryOracle(id);
        rewards.rollover(id);
        vm.prank(Network.INTAKE);
        vm.expectRevert(HolderRewards.UnknownRequest.selector);
        rewards.onOracleResult(rid, a, sig);
    }

    function test_failedTokenTransferRollsBackClaimAndCanBeRetried() public {
        uint256 id = _deposit(10 ether);
        _answer(id, _leaf(alice, 9.5 ether));
        imd.setFailTransfers(true);
        vm.prank(alice);
        vm.expectRevert();
        rewards.claim(id, 9.5 ether, new bytes32[](0));
        assertFalse(rewards.hasClaimed(id, alice));
        assertEq(rewards.epoch(id).claimed, 0);
        imd.setFailTransfers(false);
        vm.prank(alice);
        rewards.claim(id, 9.5 ether, new bytes32[](0));
        assertEq(imd.balanceOf(alice), 9.5 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_claimAndRolloverConserveFunds(uint128 deposit, uint128 share) public {
        uint256 gross = bound(deposit, PRICE + 1, type(uint128).max);
        uint256 pot = gross - PRICE;
        uint256 amount = bound(share, 1, pot);
        uint256 id = _deposit(gross);
        _answer(id, _leaf(alice, amount));
        vm.prank(alice);
        rewards.claim(id, amount, new bytes32[](0));
        vm.warp(block.timestamp + 28 days);
        rewards.rollover(id);
        assertEq(rewards.epoch(rewards.currentEpoch()).pot, pot - amount);
        assertEq(rewards.reserved(), pot - amount);
        assertEq(imd.balanceOf(address(rewards)), pot - amount);
        assertEq(
            imd.balanceOf(alice) + imd.balanceOf(Network.INTAKE) + imd.balanceOf(address(rewards)), gross
        );
    }
}
