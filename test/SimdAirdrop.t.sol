// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {SimdAirdrop} from "../src/SimdAirdrop.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {Network} from "../src/Network.sol";
import {MockToken} from "./mocks/Mocks.sol";
import {AirdropProof} from "./fixtures/AirdropProof.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SimdAirdropTest is BaseTest {
    function _fundAndBind(uint256 extra) internal {
        if (!vault.bound()) _bind();
        token.mint(address(drop), drop.TOTAL_WEIGHT() + extra);
        vm.prank(alice);
        drop.bind(LAUNCH);
    }

    function test_realHistoricalProofMatchesExactlyTheImmutableRoot() public view {
        assertTrue(
            MerkleProof.verify(
                AirdropProof.proof(), drop.MERKLE_ROOT(), _leaf(AirdropProof.ACCOUNT, AirdropProof.WEIGHT)
            )
        );
        assertEq(drop.MERKLE_ROOT(), 0xe1fc34a5aee64c3cd01e62934929bc57511b5718c2f5ae80072ae25045e50cb4);
        assertEq(drop.TOTAL_WEIGHT(), 633028988023500000000000000);
        assertEq(drop.WALLET_COUNT(), 457);
    }

    function test_anyoneBindsOnceWhenFundedAndSetsBalanceAndThirtyDayWindow() public {
        uint256 now_ = block.timestamp;
        uint256 extra = 100 ether;
        _fundAndBind(extra);
        assertEq(drop.startBalance(), drop.TOTAL_WEIGHT() + extra);
        assertEq(drop.claimEnd(), now_ + 30 days);
        assertEq(drop.token(), address(token));
        assertEq(drop.launchNumber(), LAUNCH);
        vm.expectRevert(SimdAirdrop.AlreadyBound.selector);
        drop.bind(LAUNCH);
        token.mint(address(drop), 1 ether);
        assertEq(drop.startBalance(), drop.TOTAL_WEIGHT() + extra);
    }

    function test_bindRejectsOldLaunchEvenIfPositionAndBalanceAreValid() public {
        token.mint(address(drop), drop.TOTAL_WEIGHT());
        _position(3076, address(token), Network.IMD, address(vault));
        vm.expectRevert(SimdAirdrop.InvalidLaunch.selector);
        drop.bind(3076);
        vm.expectRevert(SimdAirdrop.InvalidLaunch.selector);
        drop.bind(0);
    }

    function test_tokensCannotMakeAnotherRequestersLaunchEligible() public {
        token.mint(address(drop), drop.TOTAL_WEIGHT());
        _position(LAUNCH, address(token), Network.IMD, alice);
        vm.expectRevert(SimdAirdrop.InvalidRequester.selector);
        drop.bind(LAUNCH);
        assertEq(drop.token(), address(0));
    }

    function test_bindRejectsOtherPairNativeAndIMDOnlyPair() public {
        token.mint(address(drop), drop.TOTAL_WEIGHT());
        MockToken other = new MockToken(18);
        _position(LAUNCH, address(token), address(other), address(vault));
        vm.expectRevert(SimdAirdrop.InvalidPair.selector);
        drop.bind(LAUNCH);
        _position(LAUNCH, Network.IMD, address(0), address(vault));
        vm.expectRevert(SimdAirdrop.InvalidPair.selector);
        drop.bind(LAUNCH);
        _position(LAUNCH, Network.IMD, Network.IMD, address(vault));
        vm.expectRevert(SimdAirdrop.InvalidPair.selector);
        drop.bind(LAUNCH);
    }

    function test_bindRequiresAtLeastTheExactTotalWeightAndAcceptsEitherCurrencyOrder() public {
        _bind();
        uint256 total = drop.TOTAL_WEIGHT();
        token.mint(address(drop), total - 1);
        vm.expectRevert(SimdAirdrop.InsufficientRemainder.selector);
        drop.bind(LAUNCH);
        token.mint(address(drop), 1);
        _position(LAUNCH, Network.IMD, address(token), address(vault));
        drop.bind(LAUNCH);
        assertEq(drop.startBalance(), total);
    }

    function test_airdropCannotBindDifferentLaunchEvenIfRequesterWasTransferredToVault() public {
        _fundAndBind(0);
        _position(LAUNCH + 1, address(token), Network.IMD, address(vault));
        vm.prank(Network.DEV);
        vm.expectRevert(SIMDVault.AlreadyBound.selector);
        vault.bindLaunch(LAUNCH + 1, address(token));
        SimdAirdrop otherDrop = new SimdAirdrop(address(vault));
        token.mint(address(otherDrop), otherDrop.TOTAL_WEIGHT());
        vm.expectRevert(SimdAirdrop.LaunchMismatch.selector);
        otherDrop.bind(LAUNCH + 1);
    }

    function test_anUnrelatedTransferredRequesterCannotFrontRunVaultBinding() public {
        token.mint(address(drop), drop.TOTAL_WEIGHT());
        vm.expectRevert(SimdAirdrop.VaultNotBound.selector);
        drop.bind(LAUNCH);
        assertEq(drop.token(), address(0));
        _bind();
        drop.bind(LAUNCH);
    }

    function test_realListedWalletClaimsItsProRataShareOnce() public {
        _fundAndBind(123 ether);
        uint256 expected = Math.mulDiv(drop.startBalance(), AirdropProof.WEIGHT, drop.TOTAL_WEIGHT());
        vm.prank(AirdropProof.ACCOUNT);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        assertEq(token.balanceOf(AirdropProof.ACCOUNT), expected);
        assertTrue(drop.claimed(AirdropProof.ACCOUNT));
        vm.prank(AirdropProof.ACCOUNT);
        vm.expectRevert(SimdAirdrop.AlreadyClaimed.selector);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        assertEq(token.balanceOf(address(drop)) + expected, drop.startBalance());
    }

    function test_badProofWrongWeightAndUnlistedWalletGetNothing() public {
        _fundAndBind(0);
        vm.prank(AirdropProof.ACCOUNT);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(AirdropProof.WEIGHT, new bytes32[](0));
        vm.prank(AirdropProof.ACCOUNT);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(AirdropProof.WEIGHT + 1, AirdropProof.proof());
        vm.prank(alice);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(AirdropProof.ACCOUNT), 0);
        assertFalse(drop.claimed(AirdropProof.ACCOUNT));
    }

    function test_claimBeforeBindAndAtClaimEndRevert() public {
        vm.prank(AirdropProof.ACCOUNT);
        vm.expectRevert(SimdAirdrop.NotBound.selector);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        _fundAndBind(0);
        vm.warp(drop.claimEnd());
        vm.prank(AirdropProof.ACCOUNT);
        vm.expectRevert(SimdAirdrop.ClaimClosed.selector);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
    }

    function test_claimImmediatelyBeforeEndSucceeds() public {
        _fundAndBind(0);
        vm.warp(drop.claimEnd() - 1);
        vm.prank(AirdropProof.ACCOUNT);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        assertEq(token.balanceOf(AirdropProof.ACCOUNT), AirdropProof.WEIGHT);
    }

    function test_burnOnlyAtOrAfterClaimEndIncludesDonationsAndCanRunAgain() public {
        vm.expectRevert(SimdAirdrop.NotBound.selector);
        drop.burnUnclaimed();
        _fundAndBind(0);
        vm.expectRevert(SimdAirdrop.ClaimStillOpen.selector);
        drop.burnUnclaimed();
        vm.prank(AirdropProof.ACCOUNT);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        token.mint(address(drop), 10 ether);
        uint256 remainder = token.balanceOf(address(drop));
        vm.warp(drop.claimEnd() - 1);
        vm.expectRevert(SimdAirdrop.ClaimStillOpen.selector);
        drop.burnUnclaimed();
        vm.warp(drop.claimEnd());
        vm.prank(bob);
        drop.burnUnclaimed();
        assertEq(token.balanceOf(Network.BURN), remainder);
        assertEq(token.balanceOf(address(drop)), 0);
        token.mint(address(drop), 3 ether);
        drop.burnUnclaimed();
        assertEq(token.balanceOf(Network.BURN), remainder + 3 ether);
        drop.burnUnclaimed();
    }

    function test_reentrantTokenCannotRepeatAClaimOrBurnEarly() public {
        _fundAndBind(0);
        token.setReentry(address(drop), abi.encodeCall(drop.burnUnclaimed, ()));
        vm.prank(AirdropProof.ACCOUNT);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        assertFalse(token.reentrySucceeded());
        assertEq(token.balanceOf(Network.BURN), 0);
    }

    function test_failedTransferLeavesClaimAvailable() public {
        _fundAndBind(0);
        token.setFailTransfers(true);
        vm.prank(AirdropProof.ACCOUNT);
        vm.expectRevert();
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        assertFalse(drop.claimed(AirdropProof.ACCOUNT));
        token.setFailTransfers(false);
        vm.prank(AirdropProof.ACCOUNT);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        assertEq(token.balanceOf(AirdropProof.ACCOUNT), AirdropProof.WEIGHT);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_realProofPayoutAndFinalBurnConserveAllTokens(uint128 extra) public {
        _fundAndBind(extra);
        uint256 start = drop.startBalance();
        uint256 expected = Math.mulDiv(start, AirdropProof.WEIGHT, drop.TOTAL_WEIGHT());
        vm.prank(AirdropProof.ACCOUNT);
        drop.claim(AirdropProof.WEIGHT, AirdropProof.proof());
        assertEq(token.balanceOf(AirdropProof.ACCOUNT), expected);
        vm.warp(drop.claimEnd());
        drop.burnUnclaimed();
        assertEq(token.balanceOf(Network.BURN) + token.balanceOf(AirdropProof.ACCOUNT), start);
    }
}
