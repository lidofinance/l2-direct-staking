// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IReceiver} from "./interfaces/IReceiver.sol";

/**
 * @title CREReceiver
 * @notice Receives signed reports from CRE workflows and executes whitelisted calls on target contracts.
 * @dev Authentication boundary — WHO may cause a call — is two layers, defense-in-depth:
 *      1. onlyForwarder   — msg.sender must be the configured CRE Forwarder, which itself only
 *                           routes DON-validated reports.
 *      2. expectedAuthor  — the report metadata's workflowOwner must equal the pinned author.
 *
 *      Authorization boundary — WHAT may be called — is the call allow-list:
 *      3. the decoded (target, selector) pair must be explicitly allowed by the owner, AND the
 *         call must be ARGUMENT-LESS: calldata must be exactly the 4-byte selector. The lone
 *         production entry is SyncTrigger.triggerSync() — a nullary, rate-limited action — so the
 *         report author controls nothing beyond which allow-listed selector fires (FINDINGS.md F-2).
 *
 *      Call chain: CRE DON → CRE Forwarder → CREReceiver.onReport() → target.call(data)
 *
 *      Intentionally NOT enforced (FINDINGS.md F-3): the report's workflowName (metadata[32:42])
 *      and workflowId (metadata[0:32]) are populated by the DON but not checked here. The
 *      workflowName is an owner-chosen, owner-scoped label — not globally unique, and an attacker
 *      who controls the pinned owner key can register a workflow under the expected name, so a
 *      name bind adds no protection against the principal threat (owner-key compromise). Because
 *      execution is already constrained to a single argument-less call (layer 3), a stray workflow
 *      signed by the same owner could at most trigger the intended, rate-limited sync; binding the
 *      name would only add operational rigidity (a workflow rename ⇒ redeploy) for a negligible
 *      gain. The authentication boundary is therefore deliberately "(forwarder, workflowOwner)".
 *      See DOC.md.
 *
 *      Invariants:
 *      - _expectedAuthor is never address(0) (enforced at construction and by setters).
 *      - By design, CREReceiver holds no on-chain privileges other than being the forwarder on
 *        its target.
 */
contract CREReceiver is IReceiver, IERC165, Ownable {
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
    error NonNullaryCall(address target, uint256 length);
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
        // workflowName/workflowId intentionally not checked — see contract @dev / FINDINGS.md F-3.
        address workflowOwner = _extractWorkflowOwner(metadata);
        if (workflowOwner != _expectedAuthor) {
            revert InvalidAuthor(workflowOwner, _expectedAuthor);
        }

        (address target, bytes memory data) = abi.decode(report, (address, bytes));
        if (target == address(0)) revert InvalidTargetAddress();
        if (data.length < 4) revert ReportTooShort(data.length);

        bytes4 selector = bytes4(data);
        if (!_allowedCalls[target][selector]) revert CallNotAllowed(target, selector);

        // F-2: every allow-listed call is argument-less (the production seed is the nullary
        // SyncTrigger.triggerSync()). Reject any calldata beyond the bare 4-byte selector so the
        // report author cannot control the arguments passed to target.call(data).
        if (data.length != 4) revert NonNullaryCall(target, data.length);

        (bool success, bytes memory returnData) = target.call(data);
        if (!success) revert CallExecutionFailed(target, returnData);

        emit CallExecuted(target, selector, returnData);
    }

    /// @notice Returns the forwarder address that is allowed to call `onReport`.
    /// @dev Convenience accessor for off-chain tooling / deploy verification. Deliberately NOT
    ///      part of `IReceiver`: keeping it out preserves `type(IReceiver).interfaceId == 0x805f2132`.
    function getForwarder() external view returns (address) {
        return _forwarder;
    }

    /// @inheritdoc IERC165
    /// @dev The CRE Keystone forwarder gates delivery on
    ///      `ERC165Checker.supportsInterface(receiver, type(IReceiver).interfaceId)` (0x805f2132),
    ///      which first probes the ERC-165 base id (0x01ffc9a7). BOTH must return true, or the
    ///      forwarder marks the receiver invalid and never calls `onReport`.
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IReceiver).interfaceId // 0x805f2132 (onReport-only IReceiver)
            || interfaceId == type(IERC165).interfaceId; // 0x01ffc9a7 (ERC-165 base)
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
