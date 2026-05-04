// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";

/**
 * @title CREReceiver
 * @notice Receives signed reports from CRE workflows and executes whitelisted calls on target contracts.
 * @dev Three independent access controls layer defense:
 *      1. onlyForwarder   — msg.sender must be the configured CRE Forwarder.
 *      2. expectedAuthor  — the report metadata's workflowOwner must match the expected author.
 *      3. call allow-list — the decoded (target, selector) pair must be explicitly allowed by the owner.
 *
 *      Call chain: CRE DON → CRE Forwarder → CREReceiver.onReport() → target.call(data)
 *
 *      Invariants:
 *      - _expectedAuthor is never address(0) (enforced at construction and by setters).
 *      - By design, CREReceiver holds no on-chain privileges other than being the forwarder on
 *        its target. See docs/SECURITY.md §6 invariant I1.
 */
contract CREReceiver is IReceiver, Ownable {
    event CallExecuted(address indexed target, bytes4 indexed selector, bytes returnData);
    event ForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event ExpectedAuthorUpdated(address indexed previousAuthor, address indexed newAuthor);
    event AllowedCallUpdated(address indexed target, bytes4 indexed selector, bool allowed);

    error UnauthorizedForwarder(address caller, address expected);
    error InvalidForwarderAddress();
    error InvalidExpectedAuthor();
    error InvalidTargetAddress();
    error InvalidAuthor(address received, address expected);
    error CallNotAllowed(address target, bytes4 selector);
    error ReportTooShort(uint256 length);
    error CallExecutionFailed(address target, bytes reason);
    error ETHTransferFailed();

    address private _forwarder;
    address private _expectedAuthor;
    mapping(address target => mapping(bytes4 selector => bool)) private _allowedCalls;

    modifier onlyForwarder() {
        if (msg.sender != _forwarder) {
            revert UnauthorizedForwarder(msg.sender, _forwarder);
        }
        _;
    }

    /// @param forwarder_ The CRE Forwarder contract address (required, nonzero).
    /// @param expectedAuthor_ The workflow-owner EVM address to pin the author check to (required, nonzero).
    /// @param allowedTarget  Initial allow-list target. Pass address(0) to seed nothing.
    /// @param allowedSelector Initial allow-list function selector for allowedTarget.
    constructor(
        address forwarder_,
        address expectedAuthor_,
        address allowedTarget,
        bytes4 allowedSelector
    ) Ownable(msg.sender) {
        if (forwarder_ == address(0)) revert InvalidForwarderAddress();
        if (expectedAuthor_ == address(0)) revert InvalidExpectedAuthor();
        _forwarder = forwarder_;
        _expectedAuthor = expectedAuthor_;
        emit ForwarderUpdated(address(0), forwarder_);
        emit ExpectedAuthorUpdated(address(0), expectedAuthor_);
        if (allowedTarget != address(0)) {
            _allowedCalls[allowedTarget][allowedSelector] = true;
            emit AllowedCallUpdated(allowedTarget, allowedSelector, true);
        }
    }

    /// @inheritdoc IReceiver
    function onReport(bytes calldata metadata, bytes calldata report) external override onlyForwarder {
        address workflowOwner = _extractWorkflowOwner(metadata);
        if (workflowOwner != _expectedAuthor) {
            revert InvalidAuthor(workflowOwner, _expectedAuthor);
        }

        (address target, bytes memory data) = abi.decode(report, (address, bytes));
        if (target == address(0)) revert InvalidTargetAddress();
        if (data.length < 4) revert ReportTooShort(data.length);

        bytes4 selector = bytes4(data);
        if (!_allowedCalls[target][selector]) revert CallNotAllowed(target, selector);

        (bool success, bytes memory returnData) = target.call(data);
        if (!success) revert CallExecutionFailed(target, returnData);

        emit CallExecuted(target, selector, returnData);
    }

    /// @inheritdoc IReceiver
    function getForwarder() external view override returns (address) {
        return _forwarder;
    }

    /// @inheritdoc IReceiver
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId;
    }

    function getExpectedAuthor() external view returns (address) {
        return _expectedAuthor;
    }

    function isCallAllowed(address target, bytes4 selector) external view returns (bool) {
        return _allowedCalls[target][selector];
    }

    function setForwarder(address newForwarder) external onlyOwner {
        if (newForwarder == address(0)) revert InvalidForwarderAddress();
        address prev = _forwarder;
        _forwarder = newForwarder;
        emit ForwarderUpdated(prev, newForwarder);
    }

    function setExpectedAuthor(address newAuthor) external onlyOwner {
        if (newAuthor == address(0)) revert InvalidExpectedAuthor();
        address prev = _expectedAuthor;
        _expectedAuthor = newAuthor;
        emit ExpectedAuthorUpdated(prev, newAuthor);
    }

    function setAllowedCall(address target, bytes4 selector, bool allowed) external onlyOwner {
        if (target == address(0)) revert InvalidTargetAddress();
        _allowedCalls[target][selector] = allowed;
        emit AllowedCallUpdated(target, selector, allowed);
    }

    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
    }

    /// @dev Extracts the workflow owner from packed CRE metadata.
    ///      Layout: bytes32 workflowId | bytes10 workflowName | address workflowOwner (offset 42, length 20).
    function _extractWorkflowOwner(bytes calldata metadata) internal pure returns (address workflowOwner) {
        workflowOwner = address(uint160(bytes20(metadata[42:62])));
    }

    receive() external payable {}
}
