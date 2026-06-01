// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReceiver
 * @notice Keystone receiver interface. The forwarder↔receiver contract is a SINGLE
 *         `onReport` function — this MUST mirror Chainlink's canonical Keystone `IReceiver`
 *         exactly (no extra members) so that `type(IReceiver).interfaceId == 0x805f2132`,
 *         the id the CRE Keystone forwarder probes via ERC-165 before delivering reports.
 * @dev    Do NOT add `getForwarder`/`supportsInterface` (or any other member) here:
 *         `type(IReceiver).interfaceId` is the XOR of every declared selector, so an extra
 *         member silently changes the id and the forwarder will classify the receiver as
 *         invalid and never call `onReport`. ERC-165 detection is provided by separately
 *         inheriting `IERC165`; the forwarder getter is a plain accessor on the implementation.
 */
interface IReceiver {
    /// @notice Called by the CRE forwarder to deliver a signed report
    /// @param metadata The workflow metadata (workflowId, workflowName, workflowOwner)
    /// @param report The encoded report data containing the call instructions
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
