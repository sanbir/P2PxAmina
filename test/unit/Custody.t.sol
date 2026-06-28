// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {SignedCustodyAdapter} from "../../src/custody/SignedCustodyAdapter.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Dual-signed custody attestation tests (Tech Spec S3).
contract CustodyTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");

    function _proof(uint64 observedAt, uint64 expiresAt)
        internal
        view
        returns (SignedCustodyAdapter.PledgeProof memory)
    {
        return SignedCustodyAdapter.PledgeProof({
            custodyAccountRef: bytes32("acct-1"),
            token: address(cbtc),
            amount: 10e8,
            decimals: 8,
            observedAt: observedAt,
            expiresAt: expiresAt,
            controlAgreementHash: bytes32("ctrl")
        });
    }

    function _hash(SignedCustodyAdapter.PledgeProof memory p) internal view returns (bytes32) {
        bytes32 sh = keccak256(
            abi.encode(
                keccak256(
                    "PledgeProof(bytes32 pledgeId,bytes32 custodyAccountRef,address token,uint256 amount,uint8 decimals,uint64 observedAt,uint64 expiresAt,bytes32 controlAgreementHash)"
                ),
                pid,
                p.custodyAccountRef,
                p.token,
                p.amount,
                p.decimals,
                p.observedAt,
                p.expiresAt,
                p.controlAgreementHash
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSep("TrioraCustodyAdapter", "1", address(custody)), sh));
    }

    function _sig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_validDualSig_accepted() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        bytes32 d = _hash(p);
        custody.submitPledgeProof(pid, p, _sig(custodianPk, d), _sig(aminaSignerPk, d));
        assertTrue(custody.isLockActive(pid));
        assertTrue(custody.verifyPledge(pid, address(cbtc), 10e8));
        assertFalse(custody.verifyPledge(pid, address(cbtc), 11e8)); // amount > attested
    }

    function test_missingAminaSig_reverts() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        bytes32 d = _hash(p);
        // both slots signed by custodian → amina slot recovers to wrong signer
        vm.expectRevert(Errors.BadSignature.selector);
        custody.submitPledgeProof(pid, p, _sig(custodianPk, d), _sig(custodianPk, d));
    }

    function test_wrongSigner_reverts() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        bytes32 d = _hash(p);
        uint256 evilPk = 0xDEAD;
        vm.expectRevert(Errors.BadSignature.selector);
        custody.submitPledgeProof(pid, p, _sig(evilPk, d), _sig(aminaSignerPk, d));
    }

    function test_expiredAttestation_reverts() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp - 2), uint64(block.timestamp));
        bytes32 d = _hash(p);
        vm.expectRevert(Errors.AttestationExpired.selector);
        custody.submitPledgeProof(pid, p, _sig(custodianPk, d), _sig(aminaSignerPk, d));
    }

    function test_futureAttestation_reverts() public {
        SignedCustodyAdapter.PledgeProof memory p =
            _proof(uint64(block.timestamp + 10 minutes), uint64(block.timestamp + 1 days));
        bytes32 d = _hash(p);
        vm.expectRevert(Errors.AttestationFromFuture.selector);
        custody.submitPledgeProof(pid, p, _sig(custodianPk, d), _sig(aminaSignerPk, d));
    }

    function test_lockExpires_overTime() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        bytes32 d = _hash(p);
        custody.submitPledgeProof(pid, p, _sig(custodianPk, d), _sig(aminaSignerPk, d));
        assertTrue(custody.isLockActive(pid));
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(custody.isLockActive(pid)); // attestation no longer fresh
    }
}
