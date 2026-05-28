// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IEscrowVault {
    function bindEngine(address engine) external;
    function engine() external view returns (address);

    // ledger mutators (onlyEngine)
    function credit(bytes32 dealId, address token, uint256 amount) external;
    function debit(bytes32 dealId, address token, address to, uint256 amount) external;
    function tryReleaseCollateral(bytes32 dealId, address token, address to, uint256 amount)
        external
        returns (bool success, bytes32 reasonCode);

    // pull-payment: caller transfers token in, engine credits ledger atomically
    function pull(bytes32 dealId, address token, address from, uint256 amount) external;

    // ledger views
    function getBalance(bytes32 dealId, address token) external view returns (uint256);
    function getUnattributedBalance(address token) external view returns (uint256);

    function sweepUnattributedBalance(address token, address to, uint256 amount, bytes32 reason) external;
}
