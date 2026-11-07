// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {SimdAirdrop} from "../src/SimdAirdrop.sol";
import {Network} from "../src/Network.sol";
import {MockToken, MockFactory} from "./mocks/Mocks.sol";
import {AirdropProof} from "./fixtures/AirdropProof.sol";

/// @dev Random sequences of funding, fee payouts, failing fee claims, time and distribute() calls.
contract VaultHandler is Test {
    SIMDVault public immutable vault;
    MockToken public immutable imd;
    MockToken public immutable token;
    MockFactory public immutable factory;
    address public immutable rewards;
    address public immutable jobs;

    uint256 public imdIn;
    uint256 public tokenIn;
    uint256 public nativeIn;
    uint256 public distributions;
    uint256 public lastSuccess;
    bool public hasSucceeded;
    /// @dev Each entry describes a rule broken in some call; the invariant requires none.
    string[] public violations;

    constructor(SIMDVault v, MockToken t) {
        vault = v;
        token = t;
        imd = MockToken(Network.IMD);
        factory = MockFactory(payable(Network.FACTORY));
        rewards = address(v.holderRewards());
        jobs = address(v.jobsVault());
    }

    function violationCount() external view returns (uint256) {
        return violations.length;
    }

    function fundIMD(uint96 raw) external {
        uint256 amount = _bound(raw, 0, 1_000_000 ether);
        imd.mint(address(vault), amount);
        imdIn += amount;
    }

    function fundToken(uint96 raw) external {
        uint256 amount = _bound(raw, 0, 1_000_000 ether);
        token.mint(address(vault), amount);
        tokenIn += amount;
    }

    function fundNative(uint96 raw) external {
        uint256 amount = _bound(raw, 0, 100 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        if (!ok) violations.push("vault refused native ETH");
        nativeIn += amount;
    }

    function setFeePayout(uint96 i, uint96 b, uint64 n) external {
        uint256 imdAmount = _bound(i, 0, 1_000_000 ether);
        uint256 tokenAmount = _bound(b, 0, 1_000_000 ether);
        uint256 nativeAmount = _bound(n, 0, 10 ether);
        imd.mint(address(factory), imdAmount);
        token.mint(address(factory), tokenAmount);
        vm.deal(address(factory), address(factory).balance + nativeAmount);
        imdIn += imdAmount;
        tokenIn += tokenAmount;
        nativeIn += nativeAmount;
        factory.setPayouts(imdAmount, tokenAmount, nativeAmount);
    }

    function setFactoryFails(bool value) external {
        factory.setFails(value);
    }

    function advance(uint32 raw) external {
        vm.warp(block.timestamp + _bound(raw, 1, 10 days));
        vm.roll(block.number + 10);
    }

    function distribute(address caller) external {
        uint256 v0 = imd.balanceOf(address(vault));
        uint256 f0 = imd.balanceOf(address(factory));
        uint256 j0 = imd.balanceOf(jobs);
        uint256 d0 = imd.balanceOf(Network.DEV);
        uint256 r0 = imd.balanceOf(rewards) + imd.balanceOf(Network.INTAKE);
        bool due = !hasSucceeded || block.timestamp >= lastSuccess + 7 days;
        vm.prank(caller);
        try vault.distribute() {
            if (!due) violations.push("distribute ran within 7 days of the previous one");
            hasSucceeded = true;
            lastSuccess = block.timestamp;
            ++distributions;
            uint256 b = v0 + (f0 - imd.balanceOf(address(factory)));
            if (imd.balanceOf(jobs) - j0 != b * 2572 / 10_000) violations.push("jobs share != 25.72%");
            // Dev and marketing are the same wallet: it receives both 17.14% shares.
            if (imd.balanceOf(Network.DEV) - d0 != 2 * (b * 1714 / 10_000)) {
                violations.push("dev + marketing share != 2 x 17.14%");
            }
            uint256 r1 = imd.balanceOf(rewards) + imd.balanceOf(Network.INTAKE);
            if (r1 - r0 != b * 4000 / 10_000) violations.push("holder share != 40%");
            if (imd.balanceOf(address(vault)) > 3) violations.push("more than rounding dust stayed");
            if (token.balanceOf(address(vault)) != 0) violations.push("launched token not fully burned");
            if (address(vault).balance != 0) violations.push("native ETH not sent to marketing");
        } catch (bytes memory reason) {
            if (due) violations.push("a due distribute reverted");
            if (bytes4(reason) != SIMDVault.TooSoon.selector) violations.push("unexpected revert reason");
        }
    }
}

contract VaultInvariantTest is BaseTest {
    VaultHandler handler;

    function setUp() public override {
        super.setUp();
        _bind();
        handler = new VaultHandler(vault, token);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_splitTimingAndConservation() public view {
        assertEq(handler.violationCount(), 0, handler.violationCount() == 0 ? "" : handler.violations(0));
        // IMD only leaves through the split: every wei minted is in one of these places.
        assertEq(
            imd.balanceOf(address(vault)) + imd.balanceOf(address(factory)) + imd.balanceOf(address(rewards))
                + imd.balanceOf(address(jobs)) + imd.balanceOf(Network.DEV) + imd.balanceOf(Network.INTAKE),
            handler.imdIn(),
            "IMD left the system"
        );
        // The launched token only leaves the vault to the burn address.
        assertEq(
            token.balanceOf(address(vault)) + token.balanceOf(address(factory))
                + token.balanceOf(Network.BURN),
            handler.tokenIn(),
            "launched token left other than by burn"
        );
        // Native ETH only leaves the vault to the marketing wallet.
        assertEq(
            address(vault).balance + address(factory).balance + Network.MARKETING.balance,
            handler.nativeIn(),
            "native ETH left other than to marketing"
        );
        if (handler.hasSucceeded()) {
            assertEq(vault.nextDistributionAt(), handler.lastSuccess() + 7 days);
        }
    }
}

/// @dev Random claims (the real listed wallet, forged wallets and weights), donations, time and burns.
contract AirdropHandler is Test {
    SimdAirdrop public immutable drop;
    MockToken public immutable token;
    uint256 public funded;
    uint256 public listedClaims;
    string[] public violations;

    constructor(SimdAirdrop d, MockToken t, uint256 initial) {
        drop = d;
        token = t;
        funded = initial;
    }

    function violationCount() external view returns (uint256) {
        return violations.length;
    }

    function claimListed() external {
        bool open = block.timestamp < drop.claimEnd();
        bool already = drop.claimed(AirdropProof.ACCOUNT);
        vm.prank(AirdropProof.ACCOUNT);
        try drop.claim(AirdropProof.WEIGHT, AirdropProof.proof()) {
            if (!open) violations.push("claim succeeded at or after claimEnd");
            if (already) violations.push("listed wallet claimed twice");
            ++listedClaims;
        } catch {
            if (open && !already) violations.push("valid open first claim reverted");
        }
    }

    function claimListedOtherWeight(uint256 weight) external {
        if (weight == AirdropProof.WEIGHT) weight += 1;
        vm.prank(AirdropProof.ACCOUNT);
        try drop.claim(weight, AirdropProof.proof()) {
            violations.push("listed wallet claimed with a weight not on the list");
        } catch {}
    }

    function claimForged(address who, uint256 weight, bytes32 sibling, uint8 depth) external {
        if (who == AirdropProof.ACCOUNT) return;
        bytes32[] memory proof = new bytes32[](_bound(depth, 0, 9));
        for (uint256 k; k < proof.length; ++k) {
            proof[k] = keccak256(abi.encode(sibling, k));
        }
        if (proof.length == 9) proof = AirdropProof.proof(); // the listed wallet's own proof
        vm.prank(who);
        try drop.claim(weight, proof) {
            violations.push("unlisted wallet claimed");
        } catch {}
    }

    function donate(uint96 raw) external {
        uint256 amount = _bound(raw, 0, 1_000_000 ether);
        token.mint(address(drop), amount);
        funded += amount;
    }

    function advance(uint32 raw) external {
        vm.warp(block.timestamp + _bound(raw, 1, 12 days));
    }

    function burn(address caller) external {
        bool ended = block.timestamp >= drop.claimEnd();
        vm.prank(caller);
        try drop.burnUnclaimed() {
            if (!ended) violations.push("burnUnclaimed before claimEnd");
            if (token.balanceOf(address(drop)) != 0) violations.push("burn left tokens behind");
        } catch {
            if (ended) violations.push("burnUnclaimed reverted after claimEnd");
        }
    }
}

contract AirdropInvariantTest is BaseTest {
    AirdropHandler handler;
    uint256 startBalance;
    uint256 claimEnd;

    function setUp() public override {
        super.setUp();
        _bind();
        uint256 initial = drop.TOTAL_WEIGHT() + 12_345 ether;
        token.mint(address(drop), initial);
        drop.bind(LAUNCH);
        startBalance = drop.startBalance();
        claimEnd = drop.claimEnd();
        assertEq(startBalance, initial);
        handler = new AirdropHandler(drop, token, initial);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_listedPayoutOnlyAndTokensOnlyToClaimantOrBurn() public view {
        assertEq(handler.violationCount(), 0, handler.violationCount() == 0 ? "" : handler.violations(0));
        assertLe(handler.listedClaims(), 1);
        // Bind values never move.
        assertEq(drop.startBalance(), startBalance);
        assertEq(drop.claimEnd(), claimEnd);
        assertEq(drop.token(), address(token));
        assertEq(drop.launchNumber(), LAUNCH);
        // The listed wallet holds exactly its pro-rata share once it has claimed, nothing before.
        uint256 share = startBalance * AirdropProof.WEIGHT / drop.TOTAL_WEIGHT();
        assertEq(token.balanceOf(AirdropProof.ACCOUNT), drop.claimed(AirdropProof.ACCOUNT) ? share : 0);
        // Tokens leave only to the claimant or the burn address.
        assertEq(
            token.balanceOf(address(drop)) + token.balanceOf(AirdropProof.ACCOUNT)
                + token.balanceOf(Network.BURN),
            handler.funded()
        );
    }
}
