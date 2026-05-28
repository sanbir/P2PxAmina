// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title EscrowVault — immutable per-deal token ledger.
/// @notice Holds supply + collateral for active deals. Only the bound
///         engine (set once via `bindEngine`) can credit / debit. The
///         contract is non-upgradeable: any bug in the ledger or
///         transfer logic itself has no on-chain rescue (D23). The
///         engine address is set ONCE via `bindEngine` immediately
///         after deployment.
contract EscrowVault is IEscrowVault {
    using SafeERC20 for IERC20;

    address public immutable governor; // permitted to call `sweepUnattributedBalance`
    address private _engine;

    // dealId => token => balance (ledger)
    mapping(bytes32 => mapping(address => uint256)) private _balanceOf;
    // token => sum over deals of ledger entries
    mapping(address => uint256) private _ledgerSum;

    event EngineBound(address indexed engine);
    event Credited(bytes32 indexed dealId, address indexed token, uint256 amount);
    event Debited(bytes32 indexed dealId, address indexed token, address to, uint256 amount);
    event CollateralReleased(
        bytes32 indexed dealId, address indexed to, uint256 amount, bool success, bytes32 reasonCode
    );
    event UnattributedBalanceObserved(
        address indexed token, uint256 unattributed, uint256 vaultBalance, uint256 ledgerSum
    );
    event UnattributedBalanceSwept(address indexed token, uint256 amount, address to, bytes32 reason);

    error NotGovernor();

    constructor(address governor_) {
        if (governor_ == address(0)) revert Errors.ZeroAddress();
        governor = governor_;
    }

    modifier onlyEngine() {
        if (msg.sender != _engine) revert Errors.OnlyEngine();
        _;
    }

    function bindEngine(address engine_) external {
        // One-shot binding. Only the governor (or its delegate) can bind.
        if (_engine != address(0)) revert Errors.EngineAlreadyBound();
        if (engine_ == address(0)) revert Errors.ZeroAddress();
        if (msg.sender != governor) revert NotGovernor();
        _engine = engine_;
        emit EngineBound(engine_);
    }

    function engine() external view returns (address) {
        return _engine;
    }

    // --------------- ledger mutators ---------------

    /// @notice Engine asserts `amount` was just transferred into the vault.
    ///         The vault verifies via `balanceOf` so a missing transfer
    ///         can never inflate the ledger.
    function credit(bytes32 dealId, address token, uint256 amount) external onlyEngine {
        if (amount == 0) revert Errors.ZeroAmount();
        uint256 vaultBal = IERC20(token).balanceOf(address(this));
        uint256 newSum = _ledgerSum[token] + amount;
        if (vaultBal < newSum) revert Errors.InsufficientLedger();
        _balanceOf[dealId][token] += amount;
        _ledgerSum[token] = newSum;
        emit Credited(dealId, token, amount);
    }

    /// @notice Pull `amount` from `from`, then credit. Caller (engine) is
    ///         responsible for revoking allowances on failure.
    function pull(bytes32 dealId, address token, address from, uint256 amount) external onlyEngine {
        if (amount == 0) revert Errors.ZeroAmount();
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 after_ = IERC20(token).balanceOf(address(this));
        // D17: enforce exact transfer (fee-on-transfer would be caught here
        // even if the admission check were bypassed).
        if (after_ - before != amount) revert Errors.TokenAdmissionFailed(token, bytes32("PULL_NON_EXACT"));
        _balanceOf[dealId][token] += amount;
        _ledgerSum[token] += amount;
        emit Credited(dealId, token, amount);
    }

    function debit(bytes32 dealId, address token, address to, uint256 amount) external onlyEngine {
        if (amount == 0) revert Errors.ZeroAmount();
        uint256 bal = _balanceOf[dealId][token];
        if (bal < amount) revert Errors.InsufficientLedger();
        _balanceOf[dealId][token] = bal - amount;
        _ledgerSum[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit Debited(dealId, token, to, amount);
    }

    /// @notice D18 — non-reverting collateral release. Decrements the
    ///         ledger only after the ERC-20 transfer succeeds.
    function tryReleaseCollateral(bytes32 dealId, address token, address to, uint256 amount)
        external
        onlyEngine
        returns (bool success, bytes32 reasonCode)
    {
        if (amount == 0) return (false, bytes32("ZERO"));
        uint256 bal = _balanceOf[dealId][token];
        if (bal < amount) return (false, bytes32("INSUFFICIENT"));

        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        bool transferOk = ok && (data.length == 0 || abi.decode(data, (bool)));
        if (!transferOk) {
            emit CollateralReleased(dealId, to, amount, false, bytes32("ISSUER_FREEZE"));
            return (false, bytes32("ISSUER_FREEZE"));
        }
        _balanceOf[dealId][token] = bal - amount;
        _ledgerSum[token] -= amount;
        emit CollateralReleased(dealId, to, amount, true, bytes32(0));
        return (true, bytes32(0));
    }

    // --------------- unattributed balance (D17) ---------------

    function getUnattributedBalance(address token) external view returns (uint256) {
        uint256 vaultBal = IERC20(token).balanceOf(address(this));
        uint256 ledger = _ledgerSum[token];
        return vaultBal > ledger ? vaultBal - ledger : 0;
    }

    function observeUnattributed(address token) external {
        uint256 vaultBal = IERC20(token).balanceOf(address(this));
        uint256 ledger = _ledgerSum[token];
        uint256 unatt = vaultBal > ledger ? vaultBal - ledger : 0;
        emit UnattributedBalanceObserved(token, unatt, vaultBal, ledger);
    }

    function sweepUnattributedBalance(address token, address to, uint256 amount, bytes32 reason) external {
        if (msg.sender != governor) revert NotGovernor();
        uint256 vaultBal = IERC20(token).balanceOf(address(this));
        uint256 ledger = _ledgerSum[token];
        uint256 unatt = vaultBal > ledger ? vaultBal - ledger : 0;
        if (amount > unatt) revert Errors.InsufficientLedger();
        IERC20(token).safeTransfer(to, amount);
        emit UnattributedBalanceSwept(token, amount, to, reason);
    }

    // --------------- views ---------------

    function getBalance(bytes32 dealId, address token) external view returns (uint256) {
        return _balanceOf[dealId][token];
    }

    function getLedgerSum(address token) external view returns (uint256) {
        return _ledgerSum[token];
    }
}
