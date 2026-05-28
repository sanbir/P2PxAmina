// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Compliance hook actions; constant in a fixed namespace so
///         every hook is keyed identically across upgrades.
library HookAction {
    bytes32 internal constant ACTIVATE = keccak256("ACTIVATE");
    bytes32 internal constant REPAY = keccak256("REPAY");
    bytes32 internal constant LIQUIDATE = keccak256("LIQUIDATE");
    bytes32 internal constant CLAIM = keccak256("CLAIM");
}

interface IComplianceHook {
    /// @notice View-only pre-flight check. May revert with a typed reason code.
    /// @return ok      true if compliant
    /// @return reason  zero on success; reason code on failure
    function preCheck(
        address token,
        bytes32 action,
        address from,
        address to,
        uint256 amount,
        bytes32 dealId
    ) external view returns (bool ok, bytes32 reason);

    /// @notice Post-action notification — must not revert. Engine swallows reverts.
    function postNotify(
        address token,
        bytes32 action,
        address from,
        address to,
        uint256 amount,
        bytes32 dealId
    ) external;
}

interface IComplianceRegistry {
    function preCheck(address token, bytes32 action, address from, address to, uint256 amount, bytes32 dealId)
        external
        view
        returns (bool ok, bytes32 reason);

    function postNotify(address token, bytes32 action, address from, address to, uint256 amount, bytes32 dealId)
        external;

    function getHook(address token, bytes32 action) external view returns (address);
}
