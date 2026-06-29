// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";
import {LendingEngine} from "../engine/LendingEngine.sol";
import {IPledgeRegistry} from "../interfaces/ITriora.sol";

/// @title PortfolioLens
/// @notice Read-only aggregation for the UI / indexer (Tech Spec S9). No privileges, no state.
contract PortfolioLens {
    LendingEngine public immutable engine;
    IPledgeRegistry public immutable pledges;

    struct PositionView {
        Types.Position position;
        uint256 currentOutstanding;
        uint256 healthLtvBps;
        Types.Pledge pledge;
    }

    constructor(address engine_, address pledges_) {
        engine = LendingEngine(engine_);
        pledges = IPledgeRegistry(pledges_);
    }

    function getPosition(bytes32 positionId) external view returns (PositionView memory v) {
        v.position = engine.getPosition(positionId);
        v.currentOutstanding = engine.currentOutstanding(positionId);
        v.healthLtvBps = engine.healthLtvBps(positionId);
        v.pledge = pledges.getPledge(v.position.pledgeId);
    }

    function getPledge(bytes32 pledgeId) external view returns (Types.Pledge memory, uint256 free) {
        return (pledges.getPledge(pledgeId), pledges.freeAmount(pledgeId));
    }
}
