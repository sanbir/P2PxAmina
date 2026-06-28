// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";

/// @title RiskConfig (+ ParameterArchive)
/// @notice Versioned per-market risk parameters (Tech Spec S9). Live positions pin their
///         `paramVersion`; updates snapshot the prior version into the archive so tightening LTV
///         never retroactively endangers live deals. Enforces the ladder invariant.
contract RiskConfig is TrioraAccess {
    mapping(bytes32 => Types.MarketParams) private _params;
    mapping(bytes32 => uint32) public version; // marketId => latest version
    mapping(bytes32 => mapping(uint32 => Types.MarketParams)) private _archive;

    event MarketSet(bytes32 indexed marketId, uint32 version);
    event MarketPaused(bytes32 indexed marketId);

    constructor(address roleManager_) TrioraAccess(roleManager_) {}

    function setMarket(bytes32 marketId, Types.MarketParams calldata p) external restricted(Roles.CURATOR) {
        _validate(p);
        uint32 prev = version[marketId];
        if (prev != 0) _archive[marketId][prev] = _params[marketId]; // snapshot old
        uint32 next = prev + 1;
        version[marketId] = next;
        _params[marketId] = p;
        emit MarketSet(marketId, next);
    }

    function pauseMarket(bytes32 marketId) external restricted(Roles.GUARDIAN) {
        _params[marketId].active = false;
        emit MarketPaused(marketId);
    }

    function getParams(bytes32 marketId) external view returns (Types.MarketParams memory) {
        return _params[marketId];
    }

    function getArchived(bytes32 marketId, uint32 ver) external view returns (Types.MarketParams memory) {
        return _archive[marketId][ver];
    }

    /// @dev ladder: ltv < warning < aminaLiquidation < morphoLltv <= 100% (S0.9 #6).
    function _validate(Types.MarketParams calldata p) internal pure {
        if (!(p.ltvBps < p.aminaWarningBps && p.aminaWarningBps < p.aminaLiquidationBps
                    && p.aminaLiquidationBps < p.morphoLltvBps && p.morphoLltvBps <= 10000)) revert Errors.BadConfig();
        if (p.ltvBps == 0 || p.maxRateBps == 0 || p.maxMaturity == 0) revert Errors.BadConfig();
        if (p.liquidationBonusBps > 2000 || p.aminaFeeBps > 2000) revert Errors.BadConfig();
        if (p.cureWindowSecs == 0) revert Errors.BadConfig();
    }
}
