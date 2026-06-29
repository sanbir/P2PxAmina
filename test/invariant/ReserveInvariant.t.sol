// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TrioraFixture} from "../TrioraFixture.sol";
import {PermissionedCollateralToken} from "../../src/tokens/PermissionedCollateralToken.sol";
import {ReserveToken} from "../../src/tokens/ReserveToken.sol";
import {ReserveGuard} from "../../src/reserves/ReserveGuard.sol";
import {PledgeRegistry} from "../../src/registry/PledgeRegistry.sol";

/// @notice Fuzzes minting of BOTH accounting tokens against the secure-mint guard.
contract MintHandler is Test {
    PermissionedCollateralToken cbtc;
    ReserveToken cusdc;
    bytes32[] cbtcIds;
    bytes32[] cusdcIds;

    constructor(address cbtc_, address cusdc_, bytes32[] memory ci, bytes32[] memory ri) {
        cbtc = PermissionedCollateralToken(cbtc_);
        cusdc = ReserveToken(cusdc_);
        cbtcIds = ci;
        cusdcIds = ri;
    }

    function mintCbtc(uint256 seed, uint256 amount, address to) external {
        bytes32 id = cbtcIds[seed % cbtcIds.length];
        if (to == address(0)) to = address(0xBEEF);
        amount = bound(amount, 1, 50e8);
        try cbtc.mintForPledge(to, id, amount) {} catch {}
    }

    function mintCusdc(uint256 seed, uint256 amount, address to) external {
        bytes32 id = cusdcIds[seed % cusdcIds.length];
        if (to == address(0)) to = address(0xBEEF);
        amount = bound(amount, 1, 300000e6);
        try cusdc.mintForReserve(to, id, amount) {} catch {}
    }
}

contract ReserveInvariantTest is TrioraFixture {
    MintHandler internal handler;
    bytes32[] internal cbtcIds;
    bytes32[] internal cusdcIds;

    function setUp() public override {
        super.setUp();
        // reserves smaller than total registered → the reserve guard binds and rejects over-mints
        attestReserve(address(cbtc), 200e8, 8);
        attestReserve(address(cusdc), 1000000e6, 6);
        for (uint256 i = 0; i < 3; i++) {
            bytes32 cid = keccak256(abi.encode("c", i));
            attestPledge(cid, address(cbtc), 100e8, 8);
            vm.prank(amina);
            pledges.registerPledge(cid, borrower, bytes32("a"), 100e8, bytes32("c"));
            cbtcIds.push(cid);

            bytes32 rid = keccak256(abi.encode("r", i));
            attestPledge(rid, address(cusdc), 500000e6, 6);
            vm.prank(amina);
            reserves.registerReserve(rid, lender, bytes32("a"), 500000e6, bytes32("c"));
            cusdcIds.push(rid);
        }
        handler = new MintHandler(address(cbtc), address(cusdc), cbtcIds, cusdcIds);
        rm.grantRole(keccak256("triora.role.ISSUER_MINTER"), address(handler));
        targetContract(address(handler));
    }

    /// @notice CORE SOLVENCY INVARIANT (ADR-0001 / S0.9 #1): each accounting token's supply never
    ///         exceeds its attested reserves − margin. The mint guard is the only thing standing between
    ///         "1:1 backed claim" and an unbacked claim borrowed against real value.
    function invariant_cbtcSupplyWithinReserve() public view {
        assertLe(cbtc.totalSupply(), guard.previewMintLimit(address(cbtc)));
    }

    function invariant_cusdcSupplyWithinReserve() public view {
        assertLe(cusdc.totalSupply(), guard.previewMintLimit(address(cusdc)));
    }
}
