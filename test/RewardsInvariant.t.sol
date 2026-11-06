// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {Network} from "../src/Network.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {MockToken, MockIntake} from "./mocks/Mocks.sol";

contract RewardsHandler is Test {
    HolderRewards public immutable rewards;
    MockToken public immutable imd;
    MockIntake public immutable intake;
    address public immutable vault;
    uint256 private immutable signerKey;
    address public immutable claimant;
    uint256 public totalIn;
    uint256 public totalPaid;
    uint256 private answers;
    mapping(uint256 => uint256) private amounts;

    constructor(HolderRewards r, address v, uint256 key) {
        rewards = r;
        vault = v;
        signerKey = key;
        imd = MockToken(Network.IMD);
        intake = MockIntake(Network.INTAKE);
        claimant = makeAddr("invariant claimant");
    }

    function deposit(uint96 raw) external {
        uint256 amount = _bound(raw, 1, 1000 ether);
        imd.mint(address(rewards), amount);
        totalIn += amount;
        vm.prank(vault);
        rewards.notifyDeposit();
    }

    function donate(uint96 raw) external {
        uint256 amount = _bound(raw, 1, 10 ether);
        imd.mint(address(rewards), amount);
        totalIn += amount;
    }

    function advance(uint32 raw) external {
        vm.warp(block.timestamp + _bound(raw, 1, 35 days));
        vm.roll(block.number + 1);
    }

    function availability(bool priceFails, bool requestFails) external {
        intake.setFailure(priceFails, requestFails);
    }

    function retry(uint256 raw) external {
        uint256 count = rewards.currentEpoch();
        if (count == 0) return;
        uint256 id = _bound(raw, 1, count);
        HolderRewards.Epoch memory e = rewards.epoch(id);
        if (e.closed || block.timestamp >= e.openedAt + 28 days || e.root != bytes32(0)) return;
        if (e.attempted && block.timestamp < e.lastAttempt + 1 days) return;
        rewards.retryOracle(id);
    }

    function answer(uint256 raw, uint96 share) external {
        uint256 count = rewards.currentEpoch();
        if (count == 0) return;
        uint256 id = _bound(raw, 1, count);
        HolderRewards.Epoch memory e = rewards.epoch(id);
        if (
            e.closed || block.timestamp >= e.openedAt + 28 days || e.root != bytes32(0)
                || e.requestId == bytes32(0)
        ) return;
        uint256 amount = _bound(share, 1, e.allocationBudget);
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(claimant, amount))));
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("invariant UUID", ++answers));
        a.chainId = 4663;
        a.questionHash = e.questionHash;
        a.answerType = 2;
        a.answer = abi.encode(root);
        a.fromBlock = uint64(e.snapshotBlock);
        a.toBlock = uint64(e.snapshotBlock);
        a.panelSize = 30;
        a.quorum = 20;
        a.agreed = 30;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, rewards.attestationDigest(a));
        vm.prank(Network.INTAKE);
        rewards.onOracleResult(e.requestId, a, abi.encodePacked(r, s, v));
        amounts[id] = amount;
    }

    function claim(uint256 raw) external {
        uint256 count = rewards.currentEpoch();
        if (count == 0) return;
        uint256 id = _bound(raw, 1, count);
        HolderRewards.Epoch memory e = rewards.epoch(id);
        if (
            e.closed || block.timestamp >= e.openedAt + 28 days || e.root == bytes32(0)
                || rewards.hasClaimed(id, claimant)
        ) return;
        uint256 amount = amounts[id];
        vm.prank(claimant);
        rewards.claim(id, amount, new bytes32[](0));
        totalPaid += amount;
    }

    function rollover(uint256 raw) external {
        uint256 count = rewards.currentEpoch();
        if (count == 0) return;
        uint256 id = _bound(raw, 1, count);
        HolderRewards.Epoch memory e = rewards.epoch(id);
        if (e.closed || block.timestamp < e.openedAt + 28 days) return;
        rewards.rollover(id);
    }
}

contract RewardsInvariantTest is BaseTest {
    RewardsHandler internal handler;

    function setUp() public override {
        super.setUp();
        _bind();
        handler = new RewardsHandler(rewards, address(vault), signerKey);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.availability.selector;
        selectors[4] = handler.retry.selector;
        selectors[5] = handler.answer.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.rollover.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_reservesEqualOpenPotsAndEveryWeiIsAccountedFor() public view {
        uint256 sum;
        for (uint256 id = 1; id <= rewards.currentEpoch(); ++id) {
            HolderRewards.Epoch memory e = rewards.epoch(id);
            assertLe(e.claimed, e.pot);
            assertLe(e.claimed, e.allocationBudget);
            if (!e.closed) sum += e.pot - e.claimed;
        }
        assertEq(rewards.reserved(), sum);
        assertGe(imd.balanceOf(address(rewards)), sum);
        assertEq(
            imd.balanceOf(address(rewards)) + imd.balanceOf(Network.INTAKE) + handler.totalPaid(),
            handler.totalIn()
        );
        assertEq(imd.balanceOf(handler.claimant()), handler.totalPaid());
        assertEq(imd.allowance(address(rewards), Network.INTAKE), 0);
    }
}
