// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessManagedUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IComplianceHook, IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title ComplianceRegistry — per-token/action hook routing.
/// @notice Pre-hook is a `staticcall` with bounded gas; post-hook is a
///         `call` with try/catch + bounded gas. Reverts in the post-hook
///         emit `HookFailure` and do not roll back protocol state.
contract ComplianceRegistry is Initializable, UUPSUpgradeable, AccessManagedUpgradeable, IComplianceRegistry {
    /// @custom:storage-location erc7201:p2pxamina.compliance.v1
    struct Storage {
        // hooks[token][action] => hook contract address
        mapping(address => mapping(bytes32 => address)) hooks;
        address defaultHook;
    }

    bytes32 private constant STORAGE_SLOT =
        0x4f3c8a7e2d9c1b5b6a8f7e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1b0a9f8e7d6c00;

    uint256 internal constant PRE_HOOK_GAS = 50_000;
    uint256 internal constant POST_HOOK_GAS = 30_000;

    event HookSet(address indexed token, bytes32 indexed action, address indexed hook);
    event DefaultHookSet(address indexed hook);
    event HookFailure(address indexed token, bytes32 indexed action, address indexed hook, bytes data);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address authority_, address defaultHook_) external initializer {
        __AccessManaged_init(authority_);
        __UUPSUpgradeable_init();
        if (defaultHook_ == address(0)) revert Errors.ZeroAddress();
        _store().defaultHook = defaultHook_;
        emit DefaultHookSet(defaultHook_);
    }

    function registerHook(address token, bytes32 action, address hook) external restricted {
        _store().hooks[token][action] = hook;
        emit HookSet(token, action, hook);
    }

    function setDefaultHook(address hook) external restricted {
        if (hook == address(0)) revert Errors.ZeroAddress();
        _store().defaultHook = hook;
        emit DefaultHookSet(hook);
    }

    function getHook(address token, bytes32 action) external view returns (address) {
        return _resolve(token, action);
    }

    function preCheck(address token, bytes32 action, address from, address to, uint256 amount, bytes32 dealId)
        external
        view
        returns (bool ok, bytes32 reason)
    {
        address hook = _resolve(token, action);
        bytes memory data =
            abi.encodeCall(IComplianceHook.preCheck, (token, action, from, to, amount, dealId));
        (bool callOk, bytes memory ret) = hook.staticcall{gas: PRE_HOOK_GAS}(data);
        if (!callOk || ret.length < 64) {
            return (false, bytes32("HOOK_PRE_FAIL"));
        }
        (ok, reason) = abi.decode(ret, (bool, bytes32));
    }

    function postNotify(address token, bytes32 action, address from, address to, uint256 amount, bytes32 dealId)
        external
    {
        address hook = _resolve(token, action);
        bytes memory data =
            abi.encodeCall(IComplianceHook.postNotify, (token, action, from, to, amount, dealId));
        (bool ok, bytes memory ret) = hook.call{gas: POST_HOOK_GAS}(data);
        if (!ok) {
            emit HookFailure(token, action, hook, ret);
        }
    }

    function _resolve(address token, bytes32 action) internal view returns (address) {
        Storage storage $ = _store();
        address h = $.hooks[token][action];
        return h == address(0) ? $.defaultHook : h;
    }

    function _authorizeUpgrade(address) internal override restricted {}

    function _store() private pure returns (Storage storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }
}
