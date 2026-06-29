// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {SignedCustodyAdapter} from "../../src/custody/SignedCustodyAdapter.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Dual-signed (custodian + AMINA) custody attestations (Tech Spec S3) — unchanged by Model A.
contract CustodyTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");

    function _proof(uint64 obs, uint64 exp) internal view returns (SignedCustodyAdapter.PledgeProof memory) {
        return SignedCustodyAdapter.PledgeProof({
            custodyAccountRef: bytes32("acct"),
            token: address(cbtc),
            amount: 10e8,
            decimals: 8,
            observedAt: obs,
            expiresAt: exp,
            controlAgreementHash: bytes32("ctrl")
        });
    }

    function _digest(SignedCustodyAdapter.PledgeProof memory p) internal view returns (bytes32) {
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

    function _s(uint256 pk, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    function test_validDualSig_accepted() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        bytes32 d = _digest(p);
        custody.submitPledgeProof(pid, p, _s(custodianPk, d), _s(aminaSignerPk, d));
        assertTrue(custody.isLockActive(pid));
        assertTrue(custody.verifyPledge(pid, address(cbtc), 10e8));
        assertFalse(custody.verifyPledge(pid, address(cbtc), 11e8));
    }

    function test_missingAminaSig_reverts() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        bytes32 d = _digest(p);
        vm.expectRevert(Errors.BadSignature.selector);
        custody.submitPledgeProof(pid, p, _s(custodianPk, d), _s(custodianPk, d));
    }

    function test_wrongSigner_reverts() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        bytes32 d = _digest(p);
        vm.expectRevert(Errors.BadSignature.selector);
        custody.submitPledgeProof(pid, p, _s(0xDEAD, d), _s(aminaSignerPk, d));
    }

    function test_expired_reverts() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp - 2), uint64(block.timestamp));
        bytes32 d = _digest(p);
        vm.expectRevert(Errors.AttestationExpired.selector);
        custody.submitPledgeProof(pid, p, _s(custodianPk, d), _s(aminaSignerPk, d));
    }

    function test_future_reverts() public {
        SignedCustodyAdapter.PledgeProof memory p =
            _proof(uint64(block.timestamp + 10 minutes), uint64(block.timestamp + 1 days));
        bytes32 d = _digest(p);
        vm.expectRevert(Errors.AttestationFromFuture.selector);
        custody.submitPledgeProof(pid, p, _s(custodianPk, d), _s(aminaSignerPk, d));
    }

    function test_lockExpiresOverTime() public {
        SignedCustodyAdapter.PledgeProof memory p = _proof(uint64(block.timestamp), uint64(block.timestamp + 1 days));
        bytes32 d = _digest(p);
        custody.submitPledgeProof(pid, p, _s(custodianPk, d), _s(aminaSignerPk, d));
        assertTrue(custody.isLockActive(pid));
        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(custody.isLockActive(pid));
    }
}
