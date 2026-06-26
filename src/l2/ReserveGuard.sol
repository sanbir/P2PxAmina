// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ICustodyAdapter} from "../interfaces/ICustodyAdapter.sol";
import {IReserveGuard} from "../interfaces/IReserveGuard.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title ReserveGuard -- fresh reserve-limit check for restricted cToken minting.
contract ReserveGuard is AccessManaged, IReserveGuard {
    struct ReservePolicy {
        address adapter;
        bytes32 subjectId;
        uint256 margin;
        uint64 maxStaleness;
        bool active;
    }

    mapping(address token => ReservePolicy) private _policies;

    event ReservePolicySet(
        address indexed token,
        address indexed adapter,
        bytes32 indexed subjectId,
        uint256 margin,
        uint64 maxStaleness,
        bool active
    );

    error ReservePolicyInactive(address token);
    error ReserveExceeded(address token, uint256 requested, uint256 limit);
    error ReserveReportStale(address token);

    constructor(address authority_) AccessManaged(authority_) {}

    function setReservePolicy(address token, ReservePolicy calldata policy) external restricted {
        if (token == address(0) || policy.adapter == address(0)) revert Errors.ZeroAddress();
        _policies[token] = policy;
        emit ReservePolicySet(token, policy.adapter, policy.subjectId, policy.margin, policy.maxStaleness, policy.active);
    }

    function reservePolicy(address token) external view returns (ReservePolicy memory) {
        return _policies[token];
    }

    function validateMint(address token, uint256 totalSupplyAfter) external view {
        uint256 limit = effectiveReserveLimit(token);
        if (totalSupplyAfter > limit) revert ReserveExceeded(token, totalSupplyAfter, limit);
    }

    function effectiveReserveLimit(address token) public view returns (uint256) {
        ReservePolicy storage policy = _policies[token];
        if (!policy.active) revert ReservePolicyInactive(token);

        (uint256 amount, uint8 reserveDecimals, uint64 observedAt, uint64 expiresAt) =
            ICustodyAdapter(policy.adapter).latestReserve(policy.subjectId);
        if (expiresAt <= block.timestamp) revert ReserveReportStale(token);
        if (policy.maxStaleness != 0 && block.timestamp - uint256(observedAt) > uint256(policy.maxStaleness)) {
            revert ReserveReportStale(token);
        }

        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        uint256 scaled = _scale(amount, reserveDecimals, tokenDecimals);
        if (scaled <= policy.margin) return 0;
        return scaled - policy.margin;
    }

    function _scale(uint256 amount, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) return amount * (10 ** (toDecimals - fromDecimals));
        return amount / (10 ** (fromDecimals - toDecimals));
    }
}
