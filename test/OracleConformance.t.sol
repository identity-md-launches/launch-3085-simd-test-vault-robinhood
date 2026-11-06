// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {OracleQuestion} from "../src/oracle/OracleQuestion.sol";

contract AttestationHarness is OracleAttestationConsumer {
    constructor(address signer) OracleAttestationConsumer(signer) {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata signature) external {
        _verifyAttestation(a, signature);
        _consume(a.requestId);
    }
}

contract OracleConformanceTest is Test {
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    bytes32 constant DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";

    function _vector() private pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
    }

    function test_productionDigestAndSelectorMatchIndependentProtocolVector() public {
        // This one vector is necessarily Sepolia-domain signed. Application behavior tests all use 4663.
        vm.chainId(11155111);
        vm.warp(1800000000);
        deployCodeTo(
            "HolderRewards.sol:HolderRewards",
            abi.encode(address(this), makeAddr("jobs"), makeAddr("drop")),
            VECTOR_CONSUMER
        );
        HolderRewards consumer = HolderRewards(VECTOR_CONSUMER);
        assertEq(consumer.attestationDigest(_vector()), DIGEST);
        assertEq(
            consumer.onOracleResult.selector,
            bytes4(
                keccak256(
                    "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                )
            )
        );
        vm.chainId(4663);
        assertTrue(consumer.attestationDigest(_vector()) != DIGEST);
    }

    function test_copiedVerifierAcceptsRealProtocolSignatureAndRefusesReplay() public {
        vm.chainId(11155111);
        vm.warp(1800000000);
        deployCodeTo("OracleConformance.t.sol:AttestationHarness", abi.encode(SIGNER), VECTOR_CONSUMER);
        AttestationHarness h = AttestationHarness(VECTOR_CONSUMER);
        assertEq(h.attestationDigest(_vector()), DIGEST);
        h.verify(_vector(), SIGNATURE);
        assertTrue(h.consumed(_vector().requestId));
        vm.expectRevert(
            abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, _vector().requestId)
        );
        h.verify(_vector(), SIGNATURE);
    }

    function test_questionHashMatchesIndependentProtocolVector() public pure {
        OracleQuestion.Question memory q;
        q.question = "Which Uniswap v4 pool did the most WETH volume in the last day?";
        q.chainId = 1;
        q.fromBlock = 100;
        q.toBlock = 200;
        q.answerType = 5;
        q.head = 1;
        q.definitions = new OracleQuestion.Definition[](1);
        q.definitions[0] = OracleQuestion.Definition(
            "denomination", "WETH, summed as the absolute swapped amount on the WETH side"
        );
        assertEq(OracleQuestion.hash(q), 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb);
    }
}
