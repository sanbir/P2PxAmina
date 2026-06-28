// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {TrioraMath} from "../libraries/TrioraMath.sol";
import {IReserveSource, IReserveGuard} from "../interfaces/ITriora.sol";

/// @title ReserveGuard
/// @notice On-chain secure-mint enforcement (Tech Spec S2). Sits IN the mint path: a cBTC mint
///         reverts unless `totalSupply + amount <= min(fresh sources) - positiveMargin`.
///         Fail-closed: stale / missing / discrepant reserve data blocks NEW mints (burns/repay/
///         liquidation stay possible because they do not call this).
/// @dev This is the single mechanical defence against the infinite-mint failure class.
contract ReserveGuard is IReserveGuard, TrioraAccess {
    struct Policy {
        IReserveSource primary; // launch: SignedCustodyAdapter
        IReserveSource secondary; // optional: Chainlink PoR / CRE (address(0) = unused)
        uint64 maxAge; // staleness window for sources
        uint16 marginBps; // positive reserve margin (e.g. 50 = 0.5%)
        uint16 maxDiscrepancyBps; // if two sources differ by more → fail-closed
        bool active;
    }

    mapping(address => Policy) public policyOf; // token => policy

    event PolicySet(address indexed token, address primary, address secondary, uint16 marginBps);

    constructor(address roleManager_) TrioraAccess(roleManager_) {}

    function setReservePolicy(address token, Policy calldata p) external restricted(Roles.CURATOR) {
        if (token == address(0) || address(p.primary) == address(0)) revert Errors.ZeroAddress();
        // v1 forbids negative margin implicitly (uint). Discrepancy/age must be sane.
        if (p.maxAge == 0) revert Errors.BadConfig();
        policyOf[token] = p;
        emit PolicySet(token, address(p.primary), address(p.secondary), p.marginBps);
    }

    /// @inheritdoc IReserveGuard
    function checkMint(address token, uint256 amount) external view {
        if (amount == 0) revert Errors.ZeroAmount();
        uint256 limit = previewMintLimit(token);
        uint256 supplyAfter = IERC20(token).totalSupply() + amount;
        if (supplyAfter > limit) revert Errors.ReserveExceeded(supplyAfter, limit);
    }

    /// @inheritdoc IReserveGuard
    /// @return the maximum allowed total supply for `token` right now (fail-closed → reverts if stale).
    function previewMintLimit(address token) public view returns (uint256) {
        Policy storage p = policyOf[token];
        if (!p.active || address(p.primary) == address(0)) revert Errors.ReserveSourceMissing();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        uint256 effective = _readFresh(p.primary, token, p.maxAge, tokenDecimals);

        if (address(p.secondary) != address(0)) {
            uint256 second = _readFresh(p.secondary, token, p.maxAge, tokenDecimals);
            uint256 lo = effective < second ? effective : second;
            uint256 hi = effective < second ? second : effective;
            if (hi != 0 && (hi - lo) * TrioraMath.BPS / hi > p.maxDiscrepancyBps) {
                revert Errors.ReserveDiscrepancy(effective, second);
            }
            effective = lo; // conservative: use the lower of the two
        }

        uint256 margin = effective * p.marginBps / TrioraMath.BPS;
        return effective - margin;
    }

    function _readFresh(IReserveSource src, address token, uint64 maxAge, uint8 tokenDecimals)
        internal
        view
        returns (uint256)
    {
        (uint256 amount, uint64 asOf, uint8 decimals) = src.attestedReserves(token);
        if (asOf == 0 || block.timestamp > uint256(asOf) + maxAge) revert Errors.ReserveStale();
        return TrioraMath.scaleDecimals(amount, decimals, tokenDecimals);
    }
}
