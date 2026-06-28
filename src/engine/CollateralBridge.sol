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
    IProtocolAdapter,
    IOracleAdapter,
    IReleaseAuthorizer,
    ISettlementRouter,
    IPermissionedCollateralToken,
    IPledgeRegistry
} from "../interfaces/ITriora.sol";
import {KYBGateway} from "../identity/KYBGateway.sol";
import {RiskConfig} from "../config/RiskConfig.sol";
import {PositionRegistry} from "../registry/PositionRegistry.sol";

/// @title CollateralBridge
/// @notice The Triora Core lending engine (Tech Spec S6). It owns the isolated Morpho position via the
///         {MorphoAdapter}, keeps a per-borrower sub-ledger (Morpho sees only one aggregate position),
///         and orchestrates the full lifecycle: open (mint→supply cBTC→borrow USDC to borrower),
///         accrue (fixed APR), repay→release, top-up, and the AMINA-operated liquidation path.
/// @dev Real BTC never enters here; the bridge holds only cBTC accounting tokens in-flight to Morpho.
contract CollateralBridge is TrioraAccess, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // wiring (one-shot)
    KYBGateway public kyb;
    IPledgeRegistry public pledges;
    IPermissionedCollateralToken public cbtc;
    IERC20 public cbtcErc;
    IProtocolAdapter public adapter;
    IOracleAdapter public oracle;
    IReleaseAuthorizer public releaseAuth;
    ISettlementRouter public router;
    RiskConfig public riskConfig;
    PositionRegistry public positions;
    bytes32 public marketId;
    IERC20 public usdc;
    address public aminaTreasury; // funds liquidation repay of Morpho debt
    address public aminaDesk; // destination of seized collateral release
    bool private _wired;

    // sub-ledger
    mapping(bytes32 => Types.Position) private _position;
    mapping(bytes32 => bytes32) public voucherPrimary;
    mapping(bytes32 => bytes32) public voucherSurplus;
    mapping(bytes32 => bool) public liqExecuted;
    mapping(bytes32 => bool) public liqDefaulted;
    mapping(address => uint256) public borrowerDebt;
    uint256 public marketDebt;
    uint256 private _nonce;

    event PositionOpened(bytes32 indexed positionId, address indexed borrower, uint256 collateral, uint256 principal);
    event Repaid(bytes32 indexed positionId, uint256 amount, uint256 outstanding);
    event ReleasePending(bytes32 indexed positionId, bytes32 voucherId);
    event Closed(bytes32 indexed positionId);
    event ToppedUp(bytes32 indexed positionId, uint256 amount, uint256 newCollateral);
    event Warned(bytes32 indexed positionId, uint64 cureDeadline);
    event LiquidationPendingSet(bytes32 indexed positionId, uint64 cureDeadline);
    event LiquidationCancelled(bytes32 indexed positionId);
    event LiquidationExecuted(bytes32 indexed positionId, uint256 seized, uint256 surplus, bool defaulted);
    event Liquidated(bytes32 indexed positionId);

    constructor(address roleManager_, address usdc_, address aminaTreasury_, address aminaDesk_)
        TrioraAccess(roleManager_)
    {
        if (usdc_ == address(0) || aminaTreasury_ == address(0) || aminaDesk_ == address(0)) {
            revert Errors.ZeroAddress();
        }
        usdc = IERC20(usdc_);
        aminaTreasury = aminaTreasury_;
        aminaDesk = aminaDesk_;
    }

    struct Wiring {
        address kyb;
        address pledges;
        address cbtc;
        address adapter;
        address oracle;
        address releaseAuth;
        address router;
        address riskConfig;
        address positions;
        bytes32 marketId;
    }

    function wire(Wiring calldata w) external restricted(Roles.GOVERNOR) {
        if (_wired) revert Errors.AlreadySet();
        kyb = KYBGateway(w.kyb);
        pledges = IPledgeRegistry(w.pledges);
        cbtc = IPermissionedCollateralToken(w.cbtc);
        cbtcErc = IERC20(w.cbtc);
        adapter = IProtocolAdapter(w.adapter);
        oracle = IOracleAdapter(w.oracle);
        releaseAuth = IReleaseAuthorizer(w.releaseAuth);
        router = ISettlementRouter(w.router);
        riskConfig = RiskConfig(w.riskConfig);
        positions = PositionRegistry(w.positions);
        marketId = w.marketId;
        _wired = true;
    }

    // ── lifecycle ──────────────────────────────────────────────────────────────

    /// @notice AMINA (ALLOCATOR) opens a borrow position for a KYB'd borrower against a minted pledge.
    function openPosition(
        address borrower,
        bytes32 pledgeId,
        uint256 principalUsdc,
        uint32 rateBps,
        uint64 maturityTs,
        bytes32 legalTermsHash
    ) external restricted(Roles.ALLOCATOR) whenNotPaused nonReentrant returns (bytes32 positionId) {
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
        uint256 collateral = pledges.freeAmount(pledgeId);
        if (collateral == 0) revert Errors.ZeroAmount();

        // LTV check (value in 1e8 USD → USDC 1e6)
        uint256 collUsd = oracle.collateralValueUsd(collateral);
        uint256 maxBorrowUsdc = (collUsd * mp.ltvBps / TrioraMath.BPS) / 1e2;
        if (principalUsdc == 0 || principalUsdc > maxBorrowUsdc) {
            revert Errors.LtvExceeded(principalUsdc, maxBorrowUsdc);
        }

        // caps
        if (borrowerDebt[borrower] + principalUsdc > mp.perBorrowerCapUsdc) revert Errors.CapExceeded();
        if (marketDebt + principalUsdc > mp.marketCapUsdc) revert Errors.CapExceeded();

        positionId = keccak256(abi.encode(block.chainid, address(this), borrower, pledgeId, ++_nonce));

        pledges.lockForDeal(pledgeId, positionId, collateral);

        // supply cBTC collateral to Morpho, then borrow USDC straight to the borrower
        cbtcErc.forceApprove(address(adapter), collateral);
        adapter.supplyCollateral(collateral);
        adapter.borrow(principalUsdc, borrower);

        _position[positionId] = Types.Position({
            borrower: borrower,
            pledgeId: pledgeId,
            collateral: collateral,
            principal: principalUsdc,
            outstanding: principalUsdc,
            rateBps: rateBps,
            startTs: uint64(block.timestamp),
            maturityTs: maturityTs,
            lastAccrueTs: uint64(block.timestamp),
            state: Types.PositionState.Active,
            paramVersion: riskConfig.version(marketId),
            cureDeadline: 0
        });
        positions.record(
            positionId,
            PositionRegistry.Terms({
                borrower: borrower,
                pledgeId: pledgeId,
                principal: principalUsdc,
                rateBps: rateBps,
                startTs: uint64(block.timestamp),
                maturityTs: maturityTs,
                marketId: marketId,
                legalTermsHash: legalTermsHash
            })
        );
        borrowerDebt[borrower] += principalUsdc;
        marketDebt += principalUsdc;

        router.emitInstruction("POSITION_OPENED", positionId, bytes32(0), "");
        emit PositionOpened(positionId, borrower, collateral, principalUsdc);
    }

    /// @notice Repay (borrower or AMINA). Full repayment withdraws collateral and issues a borrower voucher.
    function repay(bytes32 positionId, uint256 amount) external whenNotPaused nonReentrant {
        Types.Position storage p = _position[positionId];
        if (
            p.state != Types.PositionState.Active && p.state != Types.PositionState.Warned
                && p.state != Types.PositionState.RepaymentPending
        ) revert Errors.BadPositionState(uint8(p.state));
        if (msg.sender != p.borrower && !_hasRole(Roles.ALLOCATOR, msg.sender)) {
            revert Errors.NotAuthorized(Roles.ALLOCATOR, msg.sender);
        }

        adapter.accrue();
        _accrue(positionId);

        uint256 pay = amount > p.outstanding ? p.outstanding : amount;
        if (pay == 0) revert Errors.ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), pay);
        usdc.forceApprove(address(adapter), pay);
        adapter.repay(pay);

        p.outstanding -= pay;
        borrowerDebt[p.borrower] -= pay;
        marketDebt -= pay;

        if (p.outstanding == 0) {
            adapter.withdrawCollateral(p.collateral, address(this));
            bytes32 v = releaseAuth.issueRepaymentRelease(positionId, p.pledgeId, p.borrower, p.collateral);
            voucherPrimary[positionId] = v;
            pledges.markReleasePending(p.pledgeId);
            p.state = Types.PositionState.ReleasePending;
            router.emitInstruction("RELEASE_VOUCHER", positionId, v, "");
            emit ReleasePending(positionId, v);
        } else {
            p.state = Types.PositionState.Active; // partial repay un-warns
        }
        emit Repaid(positionId, pay, p.outstanding);
    }

    /// @notice Custody listener acknowledges the off-chain BTC release; burns cBTC and finalizes.
    function confirmRelease(bytes32 positionId) external restricted(Roles.SETTLEMENT) nonReentrant {
        Types.Position storage p = _position[positionId];
        if (p.state == Types.PositionState.ReleasePending) {
            bytes32 v = voucherPrimary[positionId];
            cbtc.burnForRelease(address(this), p.pledgeId, p.collateral, v);
            pledges.markReleased(p.pledgeId, p.collateral);
            p.state = Types.PositionState.Closed;
            router.emitInstruction("RELEASE_ACK", positionId, v, "");
            emit Closed(positionId);
        } else if (p.state == Types.PositionState.LiquidationPending && liqExecuted[positionId]) {
            bytes32 v1 = voucherPrimary[positionId];
            uint256 seized = releaseAuth.getVoucher(v1).amount;
            cbtc.burnForRelease(address(this), p.pledgeId, seized, v1);
            uint256 surplus;
            bytes32 v2 = voucherSurplus[positionId];
            if (v2 != bytes32(0)) {
                surplus = releaseAuth.getVoucher(v2).amount;
                cbtc.burnForRelease(address(this), p.pledgeId, surplus, v2);
            }
            pledges.markLiquidated(p.pledgeId, p.collateral);
            p.state = liqDefaulted[positionId] ? Types.PositionState.Defaulted : Types.PositionState.Liquidated;
            router.emitInstruction("LIQUIDATION_ACK", positionId, v1, "");
            emit Liquidated(positionId);
        } else {
            revert Errors.BadPositionState(uint8(p.state));
        }
    }

    /// @notice Borrower tops up collateral from the SAME pledge's free amount (margin-call response).
    function topUpCollateral(bytes32 positionId, uint256 amount) external whenNotPaused nonReentrant {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.Active && p.state != Types.PositionState.Warned) {
            revert Errors.BadPositionState(uint8(p.state));
        }
        if (msg.sender != p.borrower && !_hasRole(Roles.ALLOCATOR, msg.sender)) {
            revert Errors.NotAuthorized(Roles.ALLOCATOR, msg.sender);
        }
        if (amount == 0 || amount > pledges.freeAmount(p.pledgeId)) revert Errors.PledgeNotFree(p.pledgeId);
        pledges.lockForDeal(p.pledgeId, positionId, amount); // adds to encumbrance (same dealId)
        cbtcErc.forceApprove(address(adapter), amount);
        adapter.supplyCollateral(amount);
        p.collateral += amount;
        if (
            p.state == Types.PositionState.Warned
                && _ltvBps(positionId) < riskConfig.getParams(marketId).aminaWarningBps
        ) {
            p.state = Types.PositionState.Active;
            p.cureDeadline = 0;
        }
        emit ToppedUp(positionId, amount, p.collateral);
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

    /// @notice Finalized by the module after the cure window. AMINA funds the Morpho repay; collateral
    ///         is withdrawn; seized + surplus vouchers are issued (surplus → borrower).
    function executeLiquidation(bytes32 positionId) external restricted(Roles.LIQUIDATION_MODULE) nonReentrant {
        Types.Position storage p = _position[positionId];
        if (p.state != Types.PositionState.LiquidationPending || liqExecuted[positionId]) {
            revert Errors.BadPositionState(uint8(p.state));
        }
        adapter.accrue();
        _accrue(positionId);
        Types.MarketParams memory mp = riskConfig.getParams(marketId);

        uint256 debt = p.outstanding;
        if (debt > 0) {
            usdc.safeTransferFrom(aminaTreasury, address(this), debt);
            usdc.forceApprove(address(adapter), debt);
            adapter.repay(debt);
            borrowerDebt[p.borrower] -= debt;
            marketDebt -= debt;
            p.outstanding = 0;
        }
        adapter.withdrawCollateral(p.collateral, address(this));

        (uint256 price,) = oracle.getPrice(); // liquidation tolerates a stale feed (AMINA has off-chain data)
        uint256 payoutUsdc = debt * (TrioraMath.BPS + mp.liquidationBonusBps + mp.aminaFeeBps) / TrioraMath.BPS;
        // cBTC(8dec) for the payout USD value: value1e8 = payoutUsdc*1e2 ; amount8 = value1e8 * 1e8 / price1e8
        uint256 seized = TrioraMath.mulDiv(payoutUsdc * 1e2, 1e8, price);

        uint256 surplus;
        bool defaulted;
        if (seized >= p.collateral) {
            seized = p.collateral;
            defaulted = true; // proceeds < amount owed to AMINA → shortfall booked off-chain
        } else {
            surplus = p.collateral - seized;
        }

        bytes32 v1 = releaseAuth.issueLiquidationRelease(positionId, p.pledgeId, aminaDesk, seized);
        voucherPrimary[positionId] = v1;
        if (surplus > 0) {
            bytes32 v2 = releaseAuth.issueSurplusRelease(positionId, p.pledgeId, p.borrower, surplus);
            voucherSurplus[positionId] = v2;
        }
        liqExecuted[positionId] = true;
        liqDefaulted[positionId] = defaulted;
        router.emitInstruction("LIQUIDATION_INSTRUCTION", positionId, v1, "");
        emit LiquidationExecuted(positionId, seized, surplus, defaulted);
    }

    // ── views ──────────────────────────────────────────────────────────────────

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

    // ── internals ────────────────────────────────────────────────────────────────

    function _accrue(bytes32 positionId) internal {
        Types.Position storage p = _position[positionId];
        uint64 end = uint64(block.timestamp) < p.maturityTs ? uint64(block.timestamp) : p.maturityTs;
        if (end > p.lastAccrueTs) {
            uint256 add = TrioraMath.linearInterest(p.principal, p.rateBps, end - p.lastAccrueTs);
            if (add > 0) {
                p.outstanding += add;
                borrowerDebt[p.borrower] += add;
                marketDebt += add;
            }
            p.lastAccrueTs = end;
        }
    }

    function _ltvBps(bytes32 positionId) internal view returns (uint256) {
        Types.Position storage p = _position[positionId];
        uint256 collUsd = oracle.collateralValueUsd(p.collateral); // 1e8
        if (collUsd == 0) return type(uint256).max;
        uint256 debtUsd = currentOutstanding(positionId) * 1e2; // 1e6 → 1e8
        return debtUsd * TrioraMath.BPS / collUsd;
    }
}
