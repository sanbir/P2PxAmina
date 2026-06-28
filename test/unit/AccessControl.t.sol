// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {Types} from "../../src/libraries/Types.sol";
import {CollateralBridge} from "../../src/engine/CollateralBridge.sol";

/// @notice Role-gating + privilege-separation tests (Tech Spec S1, S0.9 #8).
contract AccessControlTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");

    function test_openPosition_onlyAllocator() public {
        setupPledgeAndMint(pid, borrower, 10e8);
        vm.prank(stranger);
        vm.expectRevert();
        bridge.openPosition(borrower, pid, 100000e6, RATE_BPS, uint64(block.timestamp + 90 days), bytes32("l"));
    }

    function test_registerPledge_onlyAllocator() public {
        attestReserve(100e8);
        attestPledge(pid, 10e8);
        vm.prank(stranger);
        vm.expectRevert();
        pledges.registerPledge(pid, borrower, bytes32("acct-1"), 10e8, bytes32("ctrl"));
    }

    function test_recordMint_onlyTokenRole() public {
        // direct call to PledgeRegistry.recordMint from a non-token address must revert
        vm.prank(stranger);
        vm.expectRevert();
        pledges.recordMint(pid, 1e8);
    }

    function test_lockForDeal_onlyEngineRole() public {
        vm.prank(stranger);
        vm.expectRevert();
        pledges.lockForDeal(pid, bytes32("d"), 1e8);
    }

    function test_setMarket_onlyCurator() public {
        Types.MarketParams memory mp = risk.getParams(marketId);
        vm.prank(aminaBot); // LIQUIDATOR, not CURATOR
        vm.expectRevert();
        risk.setMarket(marketId, mp);
    }

    function test_confirmRelease_onlySettlement() public {
        setupPledgeAndMint(pid, borrower, 10e8);
        vm.prank(amina);
        bytes32 positionId =
            bridge.openPosition(borrower, pid, 100000e6, RATE_BPS, uint64(block.timestamp + 90 days), bytes32("l"));
        vm.prank(stranger);
        vm.expectRevert();
        bridge.confirmRelease(positionId);
    }

    function test_bridgeLiquidationHooks_onlyModule() public {
        vm.prank(aminaBot); // LIQUIDATOR holds the role to call the MODULE, not the bridge hook
        vm.expectRevert();
        bridge.setWarned(bytes32("x"), uint64(block.timestamp + 1));
    }

    function test_privilegeSeparation_allocatorCannotSetRisk() public {
        // ALLOCATOR (amina ops hot wallet for opening deals) must not be able to set risk params
        // unless ALSO granted CURATOR. Here amina happens to hold both; a pure ALLOCATOR cannot.
        address pureAllocator = makeAddr("pureAllocator");
        rm.grantRole(Roles.ALLOCATOR, pureAllocator);
        Types.MarketParams memory mp = risk.getParams(marketId);
        vm.prank(pureAllocator);
        vm.expectRevert();
        risk.setMarket(marketId, mp);
    }

    function test_pause_byGuardian_unpause_onlyEmergency() public {
        address pureGuardian = makeAddr("pureGuardian");
        rm.grantRole(Roles.GUARDIAN, pureGuardian);
        vm.prank(pureGuardian);
        bridge.pause();
        assertTrue(bridge.paused());
        // a guardian-only key cannot unpause (risk-increasing → EMERGENCY)
        vm.prank(pureGuardian);
        vm.expectRevert();
        bridge.unpause();
        vm.prank(amina); // holds EMERGENCY
        bridge.unpause();
        assertFalse(bridge.paused());
    }

    function test_wire_isOneShot_evenForGovernor() public {
        // wire already called in fixture; second call reverts (AlreadySet)
        CollateralBridge.Wiring memory w = CollateralBridge.Wiring({
            kyb: address(kyb),
            pledges: address(pledges),
            cbtc: address(cbtc),
            adapter: address(adapter),
            oracle: address(oracle),
            releaseAuth: address(release),
            router: address(router),
            riskConfig: address(risk),
            positions: address(positions),
            marketId: marketId
        });
        vm.expectRevert(Errors.AlreadySet.selector);
        bridge.wire(w); // called by this = GOVERNOR
    }
}
