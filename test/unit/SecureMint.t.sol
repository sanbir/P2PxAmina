// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TrioraFixture} from "../TrioraFixture.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {KYBGateway} from "../../src/identity/KYBGateway.sol";

/// @notice Secure-mint / Proof-of-Reserve guard tests (Tech Spec S2/S4 — anti infinite-mint).
contract SecureMintTest is TrioraFixture {
    bytes32 internal pid = keccak256("p");

    function _register(uint256 reserve8, uint256 pledge8) internal {
        attestReserve(reserve8);
        attestPledge(pid, pledge8);
        vm.prank(amina);
        pledges.registerPledge(pid, borrower, bytes32("acct-1"), pledge8, bytes32("ctrl"));
    }

    function test_mint_happy_recordsAndMints() public {
        _register(100e8, 10e8);
        vm.prank(issuer);
        cbtc.mintForPledge(address(bridge), pid, 10e8);
        assertEq(cbtc.totalSupply(), 10e8);
        assertEq(cbtc.balanceOf(address(bridge)), 10e8);
    }

    function test_mint_exceedsReserve_reverts() public {
        _register(5e8, 10e8); // reserve only 5, pledge attests 10
        vm.prank(issuer);
        vm.expectRevert(); // ReserveExceeded
        cbtc.mintForPledge(address(bridge), pid, 6e8);
    }

    function test_mint_atReserveLimit_ok_andAboveReverts() public {
        _register(100e8, 100e8);
        uint256 limit = guard.previewMintLimit(address(cbtc)); // 100e8 - 0.5% = 99.5e8
        assertEq(limit, 100e8 - (100e8 * 50 / 10000));
        vm.prank(issuer);
        cbtc.mintForPledge(address(bridge), pid, limit);
        assertEq(cbtc.totalSupply(), limit);

        bytes32 pid2 = keccak256("p2");
        attestPledge(pid2, 100e8);
        vm.prank(amina);
        pledges.registerPledge(pid2, borrower, bytes32("acct-1"), 1e8, bytes32("ctrl"));
        vm.prank(issuer);
        vm.expectRevert(); // one more wei over the limit
        cbtc.mintForPledge(address(bridge), pid2, 1);
    }

    function test_mint_exceedsPledge_reverts() public {
        _register(1000e8, 10e8); // ample reserve, pledge only 10
        vm.prank(issuer);
        vm.expectRevert(); // MintExceedsPledge
        cbtc.mintForPledge(address(bridge), pid, 11e8);
    }

    function test_staleReserve_blocksMint_failClosed() public {
        _register(100e8, 10e8);
        vm.warp(block.timestamp + 1 days + 1); // past reserve maxAge
        vm.prank(issuer);
        vm.expectRevert(Errors.ReserveStale.selector);
        cbtc.mintForPledge(address(bridge), pid, 10e8);
    }

    function test_mint_onlyIssuerMinter() public {
        _register(100e8, 10e8);
        vm.prank(stranger);
        vm.expectRevert();
        cbtc.mintForPledge(address(bridge), pid, 10e8);
    }

    function test_mint_onlyToProtocolAddress() public {
        _register(100e8, 10e8);
        vm.prank(issuer);
        vm.expectRevert(); // to=borrower is not a protocol address
        cbtc.mintForPledge(borrower, pid, 10e8);
    }

    function test_registerPledge_requiresActiveAttestation() public {
        // no attestation submitted → verifyPledge false → revert
        vm.prank(amina);
        vm.expectRevert(abi.encodeWithSelector(Errors.LockNotActive.selector, pid));
        pledges.registerPledge(pid, borrower, bytes32("acct-1"), 10e8, bytes32("ctrl"));
    }
}
