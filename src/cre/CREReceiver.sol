// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";

/**
 * @title CREReceiver
 * @notice Receives signed reports from CRE workflows and executes encoded calls on target contracts.
 * @dev The CRE DON signs a report
 *      containing `(address target, bytes data)`, the CRE Forwarder verifies the signature, and
 *      this contract decodes and executes the call.
 *
 *      Call chain: CRE DON → CRE Forwarder → CREReceiver.onReport() → target.call(data)
 */
contract CREReceiver is IReceiver, Ownable {
    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event CallExecuted(address indexed target, bytes returnData);
    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedAuthorUpdated(address indexed previousAuthor, address indexed newAuthor);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error UnauthorizedForwarder(address caller, address expected);
    error InvalidForwarderAddress();
    error InvalidTargetAddress();
    error InvalidAuthor(address received, address expected);
    error CallExecutionFailed(address target, bytes reason);
    error ETHTransferFailed();

    // ──────────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────────

    address private _forwarder;
    address private _expectedAuthor;

    // ──────────────────────────────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────────────────────────────

    modifier onlyForwarder() {
        if (msg.sender != _forwarder) {
            revert UnauthorizedForwarder(msg.sender, _forwarder);
        }
        _;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    /// @param forwarder_ The address of the CRE Forwarder contract (cannot be address(0))
    constructor(address forwarder_) Ownable(msg.sender) {
        if (forwarder_ == address(0)) revert InvalidForwarderAddress();
        _forwarder = forwarder_;
        emit ForwarderUpdated(address(0), forwarder_);
    }

    // ──────────────────────────────────────────────────────────────────────
    // IReceiver
    // ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc IReceiver
    function onReport(bytes calldata metadata, bytes calldata report) external override onlyForwarder {
        address expected = _expectedAuthor;
        if (expected != address(0)) {
            address workflowOwner = _extractWorkflowOwner(metadata);
            if (workflowOwner != expected) {
                revert InvalidAuthor(workflowOwner, expected);
            }
        }

        (address target, bytes memory data) = abi.decode(report, (address, bytes));

        if (target == address(0)) revert InvalidTargetAddress();

        (bool success, bytes memory returnData) = target.call(data);

        if (!success) revert CallExecutionFailed(target, returnData);

        emit CallExecuted(target, returnData);
    }

    /// @inheritdoc IReceiver
    function getForwarder() external view override returns (address) {
        return _forwarder;
    }

    /// @inheritdoc IReceiver
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Update the CRE Forwarder address
    /// @param newForwarder The new forwarder address (cannot be address(0))
    function setForwarder(address newForwarder) external onlyOwner {
        if (newForwarder == address(0)) revert InvalidForwarderAddress();
        address prev = _forwarder;
        _forwarder = newForwarder;
        emit ForwarderUpdated(prev, newForwarder);
    }

    /// @notice Set the expected workflow author for report validation
    /// @param author The expected author address (address(0) disables the check)
    function setExpectedAuthor(address author) external onlyOwner {
        address prev = _expectedAuthor;
        _expectedAuthor = author;
        emit ExpectedAuthorUpdated(prev, author);
    }

    /// @notice Returns the expected workflow author
    function getExpectedAuthor() external view returns (address) {
        return _expectedAuthor;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Extracts the workflow owner from packed metadata.
    ///      Layout: bytes32 workflowId | bytes10 workflowName | address workflowOwner
    function _extractWorkflowOwner(bytes calldata metadata) internal pure returns (address workflowOwner) {
        // workflowOwner starts at offset 42 (32 + 10) and is 20 bytes
        workflowOwner = address(uint160(bytes20(metadata[42:62])));
    }

    /// @notice Rescue ETH accidentally sent to the contract
    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
    }

    /// @notice Allow the contract to receive ETH
    receive() external payable {}
}
