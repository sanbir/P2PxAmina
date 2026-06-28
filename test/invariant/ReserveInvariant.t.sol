// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TrioraFixture} from "../TrioraFixture.sol";
import {PermissionedCollateralToken} from "../../src/tokens/PermissionedCollateralToken.sol";
import {ReserveGuard} from "../../src/reserves/ReserveGuard.sol";
import {PledgeRegistry} from "../../src/registry/PledgeRegistry.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {Types} from "../../src/libraries/Types.sol";

/// @notice Fuzzes minting against the secure-mint guard; the handler exhaustively attempts mints.
contract MintHandler is Test {
    PermissionedCollateralToken internal cbtc;
    PledgeRegistry internal pledges;
    address internal bridge;
    bytes32[] internal pids;

    constructor(address cbtc_, address pledges_, address bridge_, bytes32[] memory pids_) {
        cbtc = PermissionedCollateralToken(cbtc_);
        pledges = PledgeRegistry(pledges_);
        bridge = bridge_;
        pids = pids_;
    }

    /// @dev This handler holds ISSUER_MINTER, so it can mint directly. Over-limit mints revert (caught).
    function mint(uint256 seed, uint256 amount) external {
        bytes32 pid = pids[seed % pids.length];
        uint256 free = pledges.freeAmount(pid);
        if (free == 0) return;
        amount = bound(amount, 1, free);
        try cbtc.mintForPledge(bridge, pid, amount) {} catch {}
    }
}

contract ReserveInvariantTest is TrioraFixture {
    MintHandler internal handler;
    bytes32[] internal pids;
    uint256 internal constant RESERVE_8 = 200e8;

    function setUp() public override {
        super.setUp();
        // fixed, fresh reserve well above total pledged → exercises both reserve and pledge limits
        attestReserve(RESERVE_8);
        for (uint256 i = 0; i < 4; i++) {
            bytes32 pid = keccak256(abi.encode("pledge", i));
            attestPledge(pid, 100e8); // total pledged 400e8 > reserve 200e8 → reserve binds
            vm.prank(amina);
            pledges.registerPledge(pid, borrower, bytes32("acct"), 100e8, bytes32("ctrl"));
            pids.push(pid);
        }
        handler = new MintHandler(address(cbtc), address(pledges), address(bridge), pids);
        rm.grantRole(Roles.ISSUER_MINTER, address(handler));
        targetContract(address(handler));
    }

    /// @notice CORE SOLVENCY INVARIANT (S0.9 #1): cBTC supply never exceeds attested reserves − margin.
    function invariant_supplyWithinReserveLimit() public view {
        assertLe(cbtc.totalSupply(), guard.previewMintLimit(address(cbtc)));
    }

    /// @notice Per-pledge: minted never exceeds pledged (S0.9 #2).
    function invariant_mintedNeverExceedsPledged() public view {
        for (uint256 i = 0; i < pids.length; i++) {
            Types.Pledge memory p = pledges.getPledge(pids[i]);
            assertLe(p.mintedAmount, p.pledgedAmount);
        }
    }
}
