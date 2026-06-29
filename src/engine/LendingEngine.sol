// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TrioraAccess} from "../access/TrioraAccess.sol";
import {Roles} from "../libraries/Roles.sol";
import {Errors} from "../libraries/Errors.sol";
import {Types} from "../libraries/Types.sol";
import {TrioraMath} from "../libraries/TrioraMath.sol";
import {
    IOracleAdapter,
    IReleaseAuthorizer,
    ISettlementRouter,
    IPermissionedCollateralToken,
    IReserveToken,
    IPledgeRegistry,
    IReserveRegistry
} from "../interfaces/ITriora.sol";
import {KYBGateway} from "../identity/KYBGateway.sol";
import {RiskConfig} from "../config/RiskConfig.sol";
import {PositionRegistry} from "../registry/PositionRegistry.sol";

/// @title LendingEngine (Model A — pure tri-party ledger)
/// @notice Triora Core engine (ADR-0001). It NEVER holds or moves real BTC/USDC — it operates ONLY the
///         restricted accounting tokens cBTC + cUSDC and emits settlement instructions. Real USDC moves
///         ONCE, directly lender-custody → borrower-custody, OFF-CHAIN under AMINA co-signature; a
///         dual-signed ack (via {SettlementAcker}) drives the deal to Active. Repayment + collateral
///         release + liquidation run as signed instructions/acks + state-derived release vouchers.
contract LendingEngine is TrioraAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // wiring (one-shot)
    KYBGateway public kyb;
    IPledgeRegistry public pledges;
    IReserveRegistry public reserves;
    IPermissionedCollateralToken public cbtc;
    IERC20 public cbtcErc;
    IReserveToken public cusdc;
    IERC20 public cusdcErc;
    IOracleAdapter public oracle;
    IReleaseAuthorizer public releaseAuth;
    ISettlementRouter public router;
    RiskConfig public riskConfig;
    PositionRegistry public positions;
    address public acker; // the only caller of confirmFunding/confirmRepayment
    bytes32 public marketId;
    address public aminaDesk; // destination of seized collateral release (off-chain custody)
    bool private _wired;

    mapping(bytes32 => Types.Position) private _position;
    mapping(bytes32 => bytes32) public voucherPrimary;
    mapping(bytes32 => bytes32) public voucherSurplus;
    mapping(bytes32 => bool) public liqExecuted;
    mapping(bytes32 => bool) public liqDefaulted;
    mapping(address => uint256) public borrowerDebt;
    uint256 public marketDebt;
    uint256 private _nonce;

    event PositionOpened(
        bytes32 indexed id, address indexed lender, address indexed borrower, uint256 collateral, uint256 principal
    );
    event FundingInstruction(bytes32 indexed id, address lender, address borrower, uint256 principalUsdc);
    event Funded(bytes32 indexed id, bytes32 settlementRef);
    event Cancelled(bytes32 indexed id);
    event RepaymentRequested(bytes32 indexed id, uint256 quote);
    event RepaymentConfirmed(bytes32 indexed id, bytes32 settlementRef, bytes32 voucherId);
    event Closed(bytes32 indexed id);
    event Warned(bytes32 indexed id, uint64 cureDeadline);
    event LiquidationPendingSet(bytes32 indexed id, uint64 cureDeadline);
    event LiquidationCancelled(bytes32 indexed id);
    event LiquidationExecuted(bytes32 indexed id, uint256 seized, uint256 surplus, bool defaulted);
    event Liquidated(bytes32 indexed id);

    modifier onlyAcker() {
        if (msg.sender != acker) revert Errors.NotAuthorized(Roles.SETTLEMENT, msg.sender);
        _;
    }

    constructor(address roleManager_, address aminaDesk_) TrioraAccess(roleManager_) {
        if (aminaDesk_ == address(0)) revert Errors.ZeroAddress();
        aminaDesk = aminaDesk_;
    }

    struct Wiring {
        address kyb;
        address pledges;
        address reserves;
        address cbtc;
        address cusdc;
        address oracle;
        address releaseAuth;
        address router;
        address riskConfig;
        address positions;
        address acker;
        bytes32 marketId;
    }

    function wire(Wiring calldata w) external restricted(Roles.GOVERNOR) {
        if (_wired) revert Errors.AlreadySet();
        kyb = KYBGateway(w.kyb);
        pledges = IPledgeRegistry(w.pledges);
        reserves = IReserveRegistry(w.reserves);
        cbtc = IPermissionedCollateralToken(w.cbtc);
        cbtcErc = IERC20(w.cbtc);
        cusdc = IReserveToken(w.cusdc);
        cusdcErc = IERC20(w.cusdc);
        oracle = IOracleAdapter(w.oracle);
        releaseAuth = IReleaseAuthorizer(w.releaseAuth);
        router = ISettlementRouter(w.router);
        riskConfig = RiskConfig(w.riskConfig);
        positions = PositionRegistry(w.positions);
        acker = w.acker;
        marketId = w.marketId;
        _wired = true;
    }

    // ── open: match a lender + borrower; lock accounting tokens; instruct off-chain settlement ──
    function openMatchedDeal(
        address lender,
        address borrower,
        bytes32 pledgeId,
        bytes32 reserveId,
        uint256 principalUsdc,
        uint32 rateBps,
        uint64 maturityTs,
        bytes32 legalTermsHash
    ) external restricted(Roles.ALLOCATOR) whenNotPaused nonReentrant returns (bytes32 positionId) {
        kyb.requireApproved(lender);
        kyb.requireApproved(borrower);
        Types.MarketParams memory mp = riskConfig.getParams(marketId);
        if (!mp.active) revert Errors.MarketInactive();
        if (rateBps > mp.maxRateBps) revert Errors.RateTooHigh(rateBps);
        if (maturityTs <= block.timestamp || maturityTs > block.timestamp + mp.maxMaturity) {
            revert Errors.MaturityInPast();
        }

        Types.Pledge memory pl = pledges.getPledge(pledgeId);
        if (pl.owner != borrower || pl.status != Types.PledgeStatus.Minted) {
            revert Errors.BadPledgeStatus(uint8(pl.status));
        }
        Types.Reserve memory rv = reserves.getReserve(reserveId);
        if (rv.owner != lender || rv.status != Types.ReserveStatus.Available) {
            revert Errors.BadPledgeStatus(uint8(rv.status));
        }

        uint256 collateral = pledges.freeAmount(pledgeId);
        if (collateral == 0) revert Errors.ZeroAmount();
        if (principalUsdc == 0 || principalUsdc > reserves.availableAmount(reserveId)) revert Errors.ZeroAmount();

        uint256 collUsd = oracle.collateralValueUsd(collateral); // 1e8
        uint256 maxBorrowUsdc = (collUsd * mp.ltvBps / TrioraMath.BPS) / 1e2;
        if (principalUsdc > maxBorrowUsdc) revert Errors.LtvExceeded(principalUsdc, maxBorrowUsdc);

        if (borrowerDebt[borrower] + principalUsdc > mp.perBorrowerCapUsdc) revert Errors.CapExceeded();
        if (marketDebt + principalUsdc > mp.marketCapUsdc) revert Errors.CapExceeded();

        positionId = keccak256(abi.encode(block.chainid, address(this), lender, borrower, pledgeId, ++_nonce));

        pledges.lockForDeal(pledgeId, positionId, collateral);
        reserves.lockForDeal(reserveId, positionId, principalUsdc);
        // pull the accounting tokens into the engine (NOT real funds)
        cbtcErc.safeTransferFrom(borrower, address(this), collateral);
        cusdcErc.safeTransferFrom(lender, address(this), principalUsdc);

        _position[positionId] = Types.Position({
            lender: lender,
            borrower: borrower,
            pledgeId: pledgeId,
            reserveId: reserveId,
            collateral: collateral,
            principal: principalUsdc,
            outstanding: principalUsdc,
            rateBps: rateBps,
            startTs: 0,
            maturityTs: maturityTs,
            lastAccrueTs: 0,
            state: Types.PositionState.SettlementPending,
            paramVersion: riskConfig.version(marketId),
            cureDeadline: 0
        });
        positions.record(
            positionId,
            PositionRegistry.Terms({
                lender: lender,
                borrower: borrower,
                pledgeId: pledgeId,
                reserveId: reserveId,
                principal: principalUsdc,
                rateBps: rateBps,
                maturityTs: maturityTs,
                marketId: marketId,
                legalTermsHash: legalTermsHash
            })
        );
        borrowerDebt[borrower] += principalUsdc;
        marketDebt += principalUsdc;

        // instruct AMINA/custody to move real USDC ONCE, lender custody -> borrower custody
        router.emitInstruction("FUNDING_INSTRUCTION", positionId, bytes32(0), "");
        emit FundingInstruction(positionId, lender, borrower, principalUsdc);
        emit PositionOpened(positionId, lender, borrower, collateral, principalUsdc);
    }

    /// @notice Driven by {SettlementAcker} after a dual-signed FundingAck: the real USDC moved in custody.
    function confirmFunding(bytes32 positionId, bytes32 settlementRef) external onlyAcker nonReentrant {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.SettlementPending) revert Errors.BadPositionState(uint8(p.state));
        p.state = Types.PositionState.Active;
        p.startTs = uint64(block.timestamp);
        p.lastAccrueTs = uint64(block.timestamp);
        // the lender's reservation is now deployed: burn the locked cUSDC.
        reserves.markFunded(p.reserveId, p.principal);
        cusdc.burnLocked(address(this), p.principal);
        router.emitInstruction("FUNDING_CONFIRMED", positionId, settlementRef, "");
        emit Funded(positionId, settlementRef);
    }

    /// @notice Unwind a deal that never funded: return both accounting tokens to their owners.
    function cancelUnfunded(bytes32 positionId) external restricted(Roles.ALLOCATOR) nonReentrant {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.SettlementPending) revert Errors.BadPositionState(uint8(p.state));
        pledges.unlockFromDeal(p.pledgeId, p.collateral);
        reserves.unlockFromDeal(p.reserveId, p.principal);
        cbtcErc.safeTransfer(p.borrower, p.collateral);
        cusdcErc.safeTransfer(p.lender, p.principal);
        borrowerDebt[p.borrower] -= p.principal;
        marketDebt -= p.principal;
        p.state = Types.PositionState.Cancelled;
        emit Cancelled(positionId);
    }

    function requestRepayment(bytes32 positionId) external whenNotPaused {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.Active && p.state != Types.PositionState.Warned) {
            revert Errors.BadPositionState(uint8(p.state));
        }
        if (msg.sender != p.borrower && !_hasRole(Roles.ALLOCATOR, msg.sender)) {
            revert Errors.NotAuthorized(Roles.ALLOCATOR, msg.sender);
        }
        _accrue(positionId);
        p.state = Types.PositionState.RepaymentPending;
        router.emitInstruction("REPAYMENT_INSTRUCTION", positionId, bytes32(0), "");
        emit RepaymentRequested(positionId, p.outstanding);
    }

    /// @notice Driven by {SettlementAcker} after a dual-signed RepaymentAck: borrower repaid the lender
    ///         off-chain. Issue the collateral-release voucher (destination = borrower).
    function confirmRepayment(bytes32 positionId, bytes32 settlementRef) external onlyAcker nonReentrant {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.RepaymentPending && p.state != Types.PositionState.Active) {
            revert Errors.BadPositionState(uint8(p.state));
        }
        _accrue(positionId);
        p.outstanding = 0;
        borrowerDebt[p.borrower] -= 0; // debt already tracked; principal cleared logically
        marketDebt = marketDebt >= p.principal ? marketDebt - p.principal : 0;
        borrowerDebt[p.borrower] = borrowerDebt[p.borrower] >= p.principal ? borrowerDebt[p.borrower] - p.principal : 0;
        reserves.markReturned(p.reserveId);
        bytes32 v = releaseAuth.issueRepaymentRelease(positionId, p.pledgeId, p.borrower, p.collateral);
        voucherPrimary[positionId] = v;
        pledges.markReleasePending(p.pledgeId);
        p.state = Types.PositionState.ReleasePending;
        emit RepaymentConfirmed(positionId, settlementRef, v);
    }

    /// @notice Custody listener acknowledges the off-chain BTC release; burns cBTC and finalizes.
    function confirmRelease(bytes32 positionId) external restricted(Roles.SETTLEMENT) nonReentrant {
        Types.Position storage p = _position[positionId];
        if (p.state == Types.PositionState.ReleasePending) {
            cbtc.burnForRelease(address(this), p.pledgeId, p.collateral, voucherPrimary[positionId]);
            pledges.markReleased(p.pledgeId, p.collateral);
            p.state = Types.PositionState.Closed;
            emit Closed(positionId);
        } else if (p.state == Types.PositionState.LiquidationPending && liqExecuted[positionId]) {
            bytes32 v1 = voucherPrimary[positionId];
            cbtc.burnForRelease(address(this), p.pledgeId, releaseAuth.getVoucher(v1).amount, v1);
            bytes32 v2 = voucherSurplus[positionId];
            if (v2 != bytes32(0)) {
                cbtc.burnForRelease(address(this), p.pledgeId, releaseAuth.getVoucher(v2).amount, v2);
            }
            pledges.markLiquidated(p.pledgeId, p.collateral);
            p.state = liqDefaulted[positionId] ? Types.PositionState.Defaulted : Types.PositionState.Liquidated;
            emit Liquidated(positionId);
        } else {
            revert Errors.BadPositionState(uint8(p.state));
        }
    }

    // ── liquidation hooks (LiquidationModule only) ──────────────────────────────
    function setWarned(bytes32 positionId, uint64 cureDeadline) external restricted(Roles.LIQUIDATION_MODULE) {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.Active) revert Errors.BadPositionState(uint8(p.state));
        p.state = Types.PositionState.Warned;
        p.cureDeadline = cureDeadline;
        emit Warned(positionId, cureDeadline);
    }

    function setLiquidationPending(bytes32 positionId, uint64 cureDeadline)
        external
        restricted(Roles.LIQUIDATION_MODULE)
    {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.Active && p.state != Types.PositionState.Warned) {
            revert Errors.BadPositionState(uint8(p.state));
        }
        p.state = Types.PositionState.LiquidationPending;
        p.cureDeadline = cureDeadline;
        liqExecuted[positionId] = false;
        emit LiquidationPendingSet(positionId, cureDeadline);
    }

    function cancelLiquidation(bytes32 positionId) external restricted(Roles.LIQUIDATION_MODULE) {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.LiquidationPending || liqExecuted[positionId]) {
            revert Errors.BadPositionState(uint8(p.state));
        }
        p.state = Types.PositionState.Active;
        p.cureDeadline = 0;
        emit LiquidationCancelled(positionId);
    }

    /// @notice Seize cBTC for AMINA (debt+bonus+fee) and refund surplus cBTC to the borrower. NO real
    ///         USDC moves on-chain — the lender is repaid off-chain from AMINA's sale of the released BTC.
    function executeLiquidation(bytes32 positionId) external restricted(Roles.LIQUIDATION_MODULE) nonReentrant {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.LiquidationPending || liqExecuted[positionId]) {
            revert Errors.BadPositionState(uint8(p.state));
        }
        _accrue(positionId);
        Types.MarketParams memory mp = riskConfig.getParams(marketId);
        uint256 debt = p.outstanding; // USDC (6 dec)
        borrowerDebt[p.borrower] = borrowerDebt[p.borrower] >= p.principal ? borrowerDebt[p.borrower] - p.principal : 0;
        marketDebt = marketDebt >= p.principal ? marketDebt - p.principal : 0;

        (uint256 price,) = oracle.getPrice(); // 1e8; liquidation tolerates a stale feed
        uint256 payoutUsdc = debt * (TrioraMath.BPS + mp.liquidationBonusBps + mp.aminaFeeBps) / TrioraMath.BPS;
        // cBTC(8dec) covering the payout USD value: value1e8 = payoutUsdc*1e2 ; amount8 = value1e8 * 1e8 / price1e8
        uint256 seized = TrioraMath.mulDiv(payoutUsdc * 1e2, 1e8, price);

        uint256 surplus;
        bool defaulted;
        if (seized >= p.collateral) {
            seized = p.collateral;
            defaulted = true;
        } else {
            surplus = p.collateral - seized;
        }

        bytes32 v1 = releaseAuth.issueLiquidationRelease(positionId, p.pledgeId, aminaDesk, seized);
        voucherPrimary[positionId] = v1;
        if (surplus > 0) {
            voucherSurplus[positionId] = releaseAuth.issueSurplusRelease(positionId, p.pledgeId, p.borrower, surplus);
        }
        liqExecuted[positionId] = true;
        liqDefaulted[positionId] = defaulted;
        router.emitInstruction("LIQUIDATION_INSTRUCTION", positionId, v1, "");
        emit LiquidationExecuted(positionId, seized, surplus, defaulted);
    }

    // ── views ───────────────────────────────────────────────────────────────────
    function getPosition(bytes32 positionId) external view returns (Types.Position memory) {
        return _position[positionId];
    }

    function currentOutstanding(bytes32 positionId) public view returns (uint256) {
        Types.Position storage p = _position[positionId];
        if (
            p.state != Types.PositionState.Active && p.state != Types.PositionState.Warned
                && p.state != Types.PositionState.RepaymentPending
        ) return p.outstanding;
        uint64 end = uint64(block.timestamp) < p.maturityTs ? uint64(block.timestamp) : p.maturityTs;
        uint256 add = end > p.lastAccrueTs ? TrioraMath.linearInterest(p.principal, p.rateBps, end - p.lastAccrueTs) : 0;
        return p.outstanding + add;
    }

    function healthLtvBps(bytes32 positionId) external view returns (uint256) {
        return _ltvBps(positionId);
    }

    // ── internals ─────────────────────────────────────────────────────────────────
    function _accrue(bytes32 positionId) internal {
        Types.Position storage p = _position[positionId];
        if (p.startTs == 0) return; // not funded yet → no interest
        uint64 end = uint64(block.timestamp) < p.maturityTs ? uint64(block.timestamp) : p.maturityTs;
        if (end > p.lastAccrueTs) {
            uint256 add = TrioraMath.linearInterest(p.principal, p.rateBps, end - p.lastAccrueTs);
            if (add > 0) p.outstanding += add;
            p.lastAccrueTs = end;
        }
    }

    function _ltvBps(bytes32 positionId) internal view returns (uint256) {
        Types.Position storage p = _position[positionId];
        uint256 collUsd = oracle.collateralValueUsd(p.collateral); // 1e8
        if (collUsd == 0) return type(uint256).max;
        uint256 debtUsd = currentOutstanding(positionId) * 1e2;
        return debtUsd * TrioraMath.BPS / collUsd;
    }
}
