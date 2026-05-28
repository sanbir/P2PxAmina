// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILendingEngine} from "../interfaces/ILendingEngine.sol";
import {IDealRegistry} from "../interfaces/IDealRegistry.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {Types} from "../libraries/Types.sol";

/// @title PortfolioLens — immutable read-only views aggregator.
/// @notice Off-chain tooling (dashboards, auditor scripts) reads this
///         instead of stitching together state across registries.
contract PortfolioLens {
    ILendingEngine public immutable engine;
    IDealRegistry public immutable deals;
    IEscrowVault public immutable vault;

    constructor(address engine_, address deals_, address vault_) {
        engine = ILendingEngine(engine_);
        deals = IDealRegistry(deals_);
        vault = IEscrowVault(vault_);
    }

    struct DealView {
        bytes32 dealId;
        Types.DealTerms terms;
        Types.DealState state;
        uint128 currentOutstanding;
        uint256 healthFactorBps;
        uint256 vaultSupplyBalance;
        uint256 vaultCollateralBalance;
    }

    function getDeal(bytes32 dealId) public view returns (DealView memory v) {
        v.dealId = dealId;
        v.terms = deals.getTerms(dealId);
        v.state = engine.getDealState(dealId);
        v.currentOutstanding = engine.computeOutstanding(dealId);
        v.healthFactorBps = engine.healthFactorBps(dealId);
        v.vaultSupplyBalance = vault.getBalance(dealId, v.terms.supplyToken);
        v.vaultCollateralBalance = vault.getBalance(dealId, v.terms.collateralToken);
    }

    function getDeals(bytes32[] calldata dealIds) external view returns (DealView[] memory out) {
        out = new DealView[](dealIds.length);
        for (uint256 i = 0; i < dealIds.length; i++) {
            out[i] = getDeal(dealIds[i]);
        }
    }

    function unattributedBalance(address token) external view returns (uint256) {
        return vault.getUnattributedBalance(token);
    }
}
