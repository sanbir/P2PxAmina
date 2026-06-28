// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../libraries/Types.sol";
import {CollateralBridge} from "../engine/CollateralBridge.sol";
import {IPledgeRegistry} from "../interfaces/ITriora.sol";

/// @title PortfolioLens
/// @notice Read-only aggregation for the UI / indexer (Tech Spec S9). No privileges, no state.
contract PortfolioLens {
    CollateralBridge public immutable bridge;
    IPledgeRegistry public immutable pledges;

    struct PositionView {
        Types.Position position;
        uint256 currentOutstanding;
        uint256 healthLtvBps;
        Types.Pledge pledge;
    }

    constructor(address bridge_, address pledges_) {
        bridge = CollateralBridge(bridge_);
        pledges = IPledgeRegistry(pledges_);
    }

    function getPosition(bytes32 positionId) external view returns (PositionView memory v) {
        v.position = bridge.getPosition(positionId);
        v.currentOutstanding = bridge.currentOutstanding(positionId);
        v.healthLtvBps = bridge.healthLtvBps(positionId);
        v.pledge = pledges.getPledge(v.position.pledgeId);
    }

    function getPledge(bytes32 pledgeId) external view returns (Types.Pledge memory, uint256 free) {
        return (pledges.getPledge(pledgeId), pledges.freeAmount(pledgeId));
    }
}
