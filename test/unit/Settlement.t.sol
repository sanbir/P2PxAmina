// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {SettlementAcker} from "../../src/settlement/SettlementAcker.sol";
import {Types} from "../../src/libraries/Types.sol";

/// @notice SettlementAcker (dual custodian+AMINA signed funding/repayment acks) — the on-chain
///         analogue of AMINA's mandatory co-signature for the off-chain real-USDC transfer.
contract SettlementTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");
    bytes32 internal rid = keccak256("r");
    bytes32 internal id;

    function setUp() public override {
        super.setUp();
        id = openDeal(pid, rid, 10e8, 100000e6, uint64(block.timestamp + 90 days));
    }

    function _fundingAck(bytes32 ref) internal view returns (SettlementAcker.Ack memory) {
        return SettlementAcker.Ack({
            positionId: id,
            amount: 100000e6,
            settlementRef: ref,
            observedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
    }

    function _sig(uint256 pk, SettlementAcker.Ack memory a, bytes32 typeHash) internal view returns (bytes memory) {
        bytes32 sh = keccak256(abi.encode(typeHash, a.positionId, a.amount, a.settlementRef, a.observedAt, a.expiresAt));
        bytes32 d =
            keccak256(abi.encodePacked("\x19\x01", _domainSep("TrioraSettlementAcker", "1", address(acker)), sh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodePacked(r, s, v);
    }

    bytes32 constant FUNDING_TH = keccak256(
        "FundingAck(bytes32 positionId,uint256 amount,bytes32 settlementRef,uint64 observedAt,uint64 expiresAt)"
    );

    function test_ackFunding_dualSigned_activates() public {
        SettlementAcker.Ack memory a = _fundingAck(bytes32("f1"));
        acker.ackFunding(a, _sig(custodianPk, a, FUNDING_TH), _sig(aminaSignerPk, a, FUNDING_TH));
        assertEq(uint8(engine.getPosition(id).state), uint8(Types.PositionState.Active));
    }

    function test_ackFunding_missingAminaSig_reverts() public {
        SettlementAcker.Ack memory a = _fundingAck(bytes32("f1"));
        vm.expectRevert(Errors.BadSignature.selector);
        acker.ackFunding(a, _sig(custodianPk, a, FUNDING_TH), _sig(custodianPk, a, FUNDING_TH));
    }

    function test_ackFunding_wrongSigner_reverts() public {
        SettlementAcker.Ack memory a = _fundingAck(bytes32("f1"));
        vm.expectRevert(Errors.BadSignature.selector);
        acker.ackFunding(a, _sig(0xDEAD, a, FUNDING_TH), _sig(aminaSignerPk, a, FUNDING_TH));
    }

    function test_ackFunding_expired_reverts() public {
        SettlementAcker.Ack memory a = SettlementAcker.Ack({
            positionId: id,
            amount: 100000e6,
            settlementRef: bytes32("f1"),
            observedAt: uint64(block.timestamp - 2),
            expiresAt: uint64(block.timestamp)
        });
        vm.expectRevert(Errors.AttestationExpired.selector);
        acker.ackFunding(a, _sig(custodianPk, a, FUNDING_TH), _sig(aminaSignerPk, a, FUNDING_TH));
    }

    function test_ackFunding_replay_reverts() public {
        SettlementAcker.Ack memory a = _fundingAck(bytes32("f1"));
        acker.ackFunding(a, _sig(custodianPk, a, FUNDING_TH), _sig(aminaSignerPk, a, FUNDING_TH));
        vm.expectRevert(); // settlementRef already consumed (and state no longer SettlementPending)
        acker.ackFunding(a, _sig(custodianPk, a, FUNDING_TH), _sig(aminaSignerPk, a, FUNDING_TH));
    }
}
