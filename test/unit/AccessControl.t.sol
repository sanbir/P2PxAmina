// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LendingEngine} from "../../src/engine/LendingEngine.sol";

/// @notice Role gating + privilege separation (Model A).
contract AccessControlTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");
    bytes32 internal rid = keccak256("r");

    function test_openMatchedDeal_onlyAllocator() public {
        setupBorrowerCbtc(pid, 10e8);
        setupLenderCusdc(rid, 100000e6);
        vm.prank(stranger);
        vm.expectRevert();
        engine.openMatchedDeal(
            lender, borrower, pid, rid, 100000e6, RATE_BPS, uint64(block.timestamp + 90 days), bytes32("l")
        );
    }

    function test_registerReserve_onlyAllocator() public {
        attestReserve(address(cusdc), 1000000e6, 6);
        attestPledge(rid, address(cusdc), 500000e6, 6);
        vm.prank(stranger);
        vm.expectRevert();
        reserves.registerReserve(rid, lender, bytes32("acct"), 500000e6, bytes32("ctrl"));
    }

    function test_confirmFunding_onlyAcker() public {
        bytes32 id = openDeal(pid, rid, 10e8, 100000e6, uint64(block.timestamp + 90 days));
        // direct call to engine.confirmFunding by a non-acker (even SETTLEMENT) reverts
        vm.prank(custodyListener);
        vm.expectRevert();
        engine.confirmFunding(id, bytes32("x"));
    }

    function test_confirmRelease_onlySettlement() public {
        bytes32 id = openDeal(pid, rid, 10e8, 100000e6, uint64(block.timestamp + 90 days));
        ackFunding(id, 100000e6, bytes32("f1"));
        vm.prank(borrower);
        engine.requestRepayment(id);
        ackRepayment(id, engine.currentOutstanding(id), bytes32("r1"));
        vm.prank(stranger);
        vm.expectRevert();
        engine.confirmRelease(id);
    }

    function test_setMarket_onlyCurator() public {
        Types.MarketParams memory mp = risk.getParams(marketId);
        vm.prank(aminaBot);
        vm.expectRevert();
        risk.setMarket(marketId, mp);
    }

    function test_engineHooks_onlyModule() public {
        vm.prank(aminaBot); // holds LIQUIDATOR (to call the module), NOT the engine hook role
        vm.expectRevert();
        engine.setWarned(bytes32("x"), uint64(block.timestamp + 1));
    }

    function test_recordMint_onlyTokenRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        reserves.recordMint(rid, 1e6);
    }

    function test_wire_oneShot() public {
        LendingEngine.Wiring memory w = LendingEngine.Wiring({
            kyb: address(kyb),
            pledges: address(pledges),
            reserves: address(reserves),
            cbtc: address(cbtc),
            cusdc: address(cusdc),
            oracle: address(oracle),
            releaseAuth: address(release),
            router: address(router),
            riskConfig: address(risk),
            positions: address(positions),
            acker: address(acker),
            marketId: marketId
        });
        vm.expectRevert(Errors.AlreadySet.selector);
        engine.wire(w);
    }
}
