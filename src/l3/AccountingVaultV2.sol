// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAccountingVaultV2} from "../interfaces/IAccountingVaultV2.sol";
import {IPermissionedCollateralToken, IReserveToken} from "../interfaces/IRestrictedToken.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title AccountingVaultV2 -- per-deal ledger for restricted cBTC and cUSDC.
contract AccountingVaultV2 is IAccountingVaultV2 {
    using SafeERC20 for IERC20;

    address public immutable governor;
    address public engine;

    mapping(bytes32 dealId => mapping(address token => uint256)) private _balanceOf;
    mapping(address token => uint256) private _ledgerSum;

    event EngineBound(address indexed engine);
    event Pulled(bytes32 indexed dealId, address indexed token, address indexed from, uint256 amount);
    event Released(bytes32 indexed dealId, address indexed token, address indexed to, uint256 amount);
    event ReserveBurned(bytes32 indexed dealId, address indexed token, uint256 amount);
    event CollateralBurned(bytes32 indexed dealId, address indexed token, bytes32 indexed pledgeId, uint256 amount);

    error NotGovernor();

    constructor(address governor_) {
        if (governor_ == address(0)) revert Errors.ZeroAddress();
        governor = governor_;
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert Errors.OnlyEngine();
        _;
    }

    function bindEngine(address engine_) external {
        if (msg.sender != governor) revert NotGovernor();
        if (engine != address(0)) revert Errors.EngineAlreadyBound();
        if (engine_ == address(0)) revert Errors.ZeroAddress();
        engine = engine_;
        emit EngineBound(engine_);
    }

    function pull(bytes32 dealId, address token, address from, uint256 amount) external onlyEngine {
        if (amount == 0) revert Errors.ZeroAmount();
        uint256 before_ = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 after_ = IERC20(token).balanceOf(address(this));
        if (after_ - before_ != amount) revert Errors.TokenAdmissionFailed(token, bytes32("NON_EXACT"));
        _balanceOf[dealId][token] += amount;
        _ledgerSum[token] += amount;
        emit Pulled(dealId, token, from, amount);
    }

    function release(bytes32 dealId, address token, address to, uint256 amount) external onlyEngine {
        _debitLedger(dealId, token, amount);
        IERC20(token).safeTransfer(to, amount);
        emit Released(dealId, token, to, amount);
    }

    function burnReserve(bytes32 dealId, address token, uint256 amount) external onlyEngine {
        _debitLedger(dealId, token, amount);
        IReserveToken(token).burnFromProtocol(address(this), amount);
        emit ReserveBurned(dealId, token, amount);
    }

    function burnCollateralForRelease(
        bytes32 dealId,
        address token,
        bytes32 pledgeId,
        uint256 amount,
        bytes32 voucherId
    ) external onlyEngine {
        _debitLedger(dealId, token, amount);
        IPermissionedCollateralToken(token).burnForRelease(address(this), pledgeId, amount, voucherId);
        emit CollateralBurned(dealId, token, pledgeId, amount);
    }

    function balanceOfDeal(bytes32 dealId, address token) external view returns (uint256) {
        return _balanceOf[dealId][token];
    }

    function ledgerSum(address token) external view returns (uint256) {
        return _ledgerSum[token];
    }

    function _debitLedger(bytes32 dealId, address token, uint256 amount) internal {
        if (amount == 0) revert Errors.ZeroAmount();
        uint256 bal = _balanceOf[dealId][token];
        if (bal < amount) revert Errors.InsufficientLedger();
        _balanceOf[dealId][token] = bal - amount;
        _ledgerSum[token] -= amount;
    }
}
