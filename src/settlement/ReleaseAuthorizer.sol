// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";
import {IReleaseAuthorizer} from "../interfaces/ITriora.sol";

/// @title ReleaseAuthorizer
/// @notice Issues one-use custody-release vouchers whose **destination is derived from state**, never
///         from the caller (Tech Spec S8). Repayment → borrower; liquidation → AMINA desk; surplus →
///         borrower. The destinationType is hard-coded per issue function, so even the engine cannot
///         mislabel a release. The cBTC token consumes a voucher (one-use) before burning.
contract ReleaseAuthorizer is IReleaseAuthorizer, TrioraAccess {
    uint64 public seqNonce;
    mapping(bytes32 => Types.ReleaseVoucher) private _vouchers;

    event VoucherIssued(
        bytes32 indexed voucherId, bytes32 indexed positionId, Types.DestinationType destinationType, uint256 amount
    );
    event VoucherConsumed(bytes32 indexed voucherId);

    constructor(address roleManager_) TrioraAccess(roleManager_) {}

    function issueRepaymentRelease(bytes32 positionId, bytes32 pledgeId, address borrower, uint256 amount)
        external
        restricted(Roles.ENGINE)
        returns (bytes32)
    {
        return _issue(positionId, pledgeId, Types.DestinationType.Borrower, borrower, 0, amount);
    }

    function issueLiquidationRelease(bytes32 positionId, bytes32 pledgeId, address aminaDesk, uint256 amount)
        external
        restricted(Roles.ENGINE)
        returns (bytes32)
    {
        return _issue(positionId, pledgeId, Types.DestinationType.AminaDesk, aminaDesk, 1, amount);
    }

    function issueSurplusRelease(bytes32 positionId, bytes32 pledgeId, address borrower, uint256 amount)
        external
        restricted(Roles.ENGINE)
        returns (bytes32)
    {
        return _issue(positionId, pledgeId, Types.DestinationType.Borrower, borrower, 2, amount);
    }

    function consume(bytes32 voucherId, bytes32 pledgeId, uint256 amount)
        external
        restricted(Roles.TOKEN)
        returns (address destination)
    {
        Types.ReleaseVoucher storage v = _vouchers[voucherId];
        if (v.issuedAt == 0 || v.pledgeId != pledgeId || v.amount != amount) revert Errors.VoucherInvalid(voucherId);
        if (v.consumed) revert Errors.VoucherConsumed(voucherId);
        v.consumed = true;
        emit VoucherConsumed(voucherId);
        return v.destination;
    }

    function getVoucher(bytes32 voucherId) external view returns (Types.ReleaseVoucher memory) {
        return _vouchers[voucherId];
    }

    function _issue(
        bytes32 positionId,
        bytes32 pledgeId,
        Types.DestinationType dType,
        address destination,
        uint8 reason,
        uint256 amount
    ) internal returns (bytes32 voucherId) {
        if (destination == address(0)) revert Errors.BadDestination();
        if (amount == 0) revert Errors.ZeroAmount();
        voucherId = keccak256(
            abi.encode(block.chainid, address(this), ++seqNonce, positionId, pledgeId, destination, reason, amount)
        );
        _vouchers[voucherId] = Types.ReleaseVoucher({
            positionId: positionId,
            pledgeId: pledgeId,
            amount: amount,
            destinationType: dType,
            destination: destination,
            reason: reason,
            issuedAt: uint64(block.timestamp),
            consumed: false
        });
        emit VoucherIssued(voucherId, positionId, dType, amount);
    }
}
