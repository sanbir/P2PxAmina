// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccountingVaultV2} from "../interfaces/IAccountingVaultV2.sol";
import {ILendingEngineV2} from "../interfaces/ILendingEngineV2.sol";
import {IPledgeRegistry} from "../interfaces/IPledgeRegistry.sol";
import {IReserveRegistry} from "../interfaces/IReserveRegistry.sol";
import {TypesV2} from "../libraries/TypesV2.sol";

/// @title PortfolioLensV2 -- read-only aggregate view for Triora v2 deals.
contract PortfolioLensV2 {
    ILendingEngineV2 public immutable engine;
    IPledgeRegistry public immutable pledges;
    IReserveRegistry public immutable reserves;
    IAccountingVaultV2 public immutable vault;

    struct DealViewV2 {
        bytes32 dealId;
        TypesV2.DealTermsV2 terms;
        TypesV2.DealRuntimeV2 runtime;
        TypesV2.Pledge pledge;
        TypesV2.Reserve reserve;
        uint128 currentOutstanding;
        uint256 vaultCollateralBalance;
        uint256 vaultReserveBalance;
    }

    constructor(address engine_, address pledges_, address reserves_, address vault_) {
        engine = ILendingEngineV2(engine_);
        pledges = IPledgeRegistry(pledges_);
        reserves = IReserveRegistry(reserves_);
        vault = IAccountingVaultV2(vault_);
    }

    function getDeal(bytes32 dealId) public view returns (DealViewV2 memory v) {
        v.dealId = dealId;
        v.terms = engine.getTerms(dealId);
        v.runtime = engine.getRuntime(dealId);
        v.pledge = pledges.getPledge(v.terms.pledgeId);
        v.reserve = reserves.getReserve(v.terms.reserveId);
        v.currentOutstanding = engine.computeOutstanding(dealId);
        v.vaultCollateralBalance = vault.balanceOfDeal(dealId, v.terms.collateralToken);
        v.vaultReserveBalance = vault.balanceOfDeal(dealId, v.terms.reserveToken);
    }
}
