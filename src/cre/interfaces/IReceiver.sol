// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReceiver
 * @notice Interface for contracts that receive and process CRE workflow reports
 */
interface IReceiver {
    /// @notice Called by the CRE forwarder to deliver a signed report
    /// @param metadata The workflow metadata (workflowId, workflowName, workflowOwner)
    /// @param report The encoded report data containing the call instructions
    function onReport(bytes calldata metadata, bytes calldata report) external;

    /// @notice Returns the forwarder address that is allowed to call onReport
    /// @return The address of the authorized forwarder
    function getForwarder() external view returns (address);

    /// @notice ERC165 interface detection
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
