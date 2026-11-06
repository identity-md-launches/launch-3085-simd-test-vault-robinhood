// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDVault} from "../src/SIMDVault.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {JobsVault} from "../src/JobsVault.sol";
import {SimdAirdrop} from "../src/SimdAirdrop.sol";
import {Network} from "../src/Network.sol";
import {PoolKey} from "../src/interfaces/IHookFactory.sol";
import {OracleAttestation} from "../src/oracle/OracleAttestation.sol";
import {MockToken, MockIntake, MockFactory, MockSigner} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test {
    uint256 internal constant PRICE = 0.5 ether;
    uint64 internal constant LAUNCH = 3077;
    SIMDVault internal vault;
    HolderRewards internal rewards;
    JobsVault internal jobs;
    SimdAirdrop internal drop;
    MockToken internal imd;
    MockToken internal token;
    MockIntake internal intake;
    MockFactory internal factory;
    address internal alice;
    address internal bob;
    uint256 internal signerKey;
    uint256 internal attestations;

    function setUp() public virtual {
        vm.chainId(4663);
        // Never etch/mock ArbSys: Foundry uses this block for its Arbitrum precompile.
        vm.roll(10_000);
        vm.warp(1_800_000_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        (address signer, uint256 key) = makeAddrAndKey("fixture oracle signer");
        signerKey = key;
        vm.etch(Network.ORACLE_SIGNER, address(new MockSigner(signer)).code);
        vm.etch(Network.IMD, address(new MockToken(18)).code);
        vm.etch(Network.INTAKE, address(new MockIntake()).code);
        vm.etch(Network.FACTORY, address(new MockFactory()).code);
        imd = MockToken(Network.IMD);
        intake = MockIntake(Network.INTAKE);
        factory = MockFactory(payable(Network.FACTORY));
        factory.setManager(makeAddr("pool manager"));
        intake.setPrice(Network.LAUNCH_ACTION, PRICE);
        intake.setPrice(Network.JOB_ACTION, PRICE);
        intake.setPrice(Network.ORACLE_ACTION, PRICE);
        token = new MockToken(18);
        vault = new SIMDVault();
        rewards = vault.holderRewards();
        jobs = vault.jobsVault();
        drop = vault.simdAirdrop();
        _position(LAUNCH, address(token), Network.IMD, address(vault));
    }

    function _position(uint64 id, address a, address b, address requester) internal {
        factory.setPosition(id, PoolKey(a, b, 12_500, 60, makeAddr("hook")), requester);
    }

    function _bind() internal {
        vm.prank(Network.DEV);
        vault.bindLaunch(LAUNCH, address(token));
    }

    function _deposit(uint256 amount) internal returns (uint256 id) {
        imd.mint(address(rewards), amount);
        vm.prank(address(vault));
        rewards.notifyDeposit();
        return rewards.currentEpoch();
    }

    function _leaf(address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(bytes.concat(a, b)) : keccak256(bytes.concat(b, a));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }

    function _attestation(uint256 id, bytes32 root)
        internal
        returns (OracleAttestation.Attestation memory a)
    {
        HolderRewards.Epoch memory e = rewards.epoch(id);
        a.requestId = keccak256(abi.encode("oracle UUID", ++attestations));
        a.chainId = 4663;
        a.questionHash = e.questionHash;
        a.answerType = OracleAttestation.ANSWER_BYTES32;
        a.answer = abi.encode(root);
        a.fromBlock = uint64(e.snapshotBlock);
        a.toBlock = uint64(e.snapshotBlock);
        a.blockHash = keccak256(abi.encode(e.snapshotBlock));
        a.panelJobId = keccak256("panel job fixture");
        a.panelSize = 30;
        a.quorum = 20;
        a.agreed = 25;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _signature(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, rewards.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _answer(uint256 id, bytes32 root) internal {
        OracleAttestation.Attestation memory a = _attestation(id, root);
        bytes memory signature = _signature(a);
        bytes32 requestId = rewards.epoch(id).requestId;
        assertTrue(requestId != bytes32(0), "oracle request must have succeeded");
        (bool delivered, bytes memory reason) = intake.deliver(requestId, abi.encode(requestId, a, signature));
        assertTrue(delivered, string(reason));
        assertEq(rewards.epoch(id).root, root);
    }

    function _nextWeek() internal {
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 100);
    }
}
