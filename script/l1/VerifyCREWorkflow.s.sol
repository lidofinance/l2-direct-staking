// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {L1MigrationConstants as L1} from "script/l1/L1MigrationConstants.sol";

/**
 * @notice Minimal read interface for Chainlink CRE `WorkflowRegistry` v2.0.0 on Ethereum mainnet.
 * @dev Source: https://sourcify.dev/#/lookup/0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5
 */
interface IWorkflowRegistryV2 {
    enum WorkflowStatus {
        ACTIVE,
        PAUSED
    }

    struct WorkflowMetadataView {
        bytes32 workflowId;
        address owner;
        uint64 createdAt;
        WorkflowStatus status;
        string workflowName;
        string binaryUrl;
        string configUrl;
        string tag;
        bytes attributes;
        string donFamily;
    }

    function getWorkflowById(bytes32 workflowId) external view returns (WorkflowMetadataView memory);
}

/**
 * @notice Read-only on-chain verification that a CRE workflow was deployed correctly
 *         and is owned by the expected author (= `CREReceiver.expectedAuthor`).
 *
 *         Runs against Ethereum mainnet — `WorkflowRegistry` lives on L1.
 *
 *         Expected owner is sourced (in order): `CRE_EXPECTED_AUTHOR`, else `L2_LIQUIDITY_OWNER` —
 *         the LOL multisig (Safe) address, which is the CRE workflow's owner and
 *         `CREReceiver.expectedAuthor` (ADR-0001 / DOC.md §3.2). The `verify-cre-workflow` recipe sets
 *         `CRE_EXPECTED_AUTHOR` to the **on-chain** `CREReceiver.getExpectedAuthor()` read over the L2
 *         RPC, so verification anchors to the authoritative on-chain pin rather than an env value that
 *         could have drifted from what Stage 1 actually pinned. The workflow is registered under the
 *         Safe via `cre workflow deploy --unsigned`, so its registry owner is the Safe address, NOT the
 *         Lido Deployer EOA that broadcasts Stage 1.
 *
 *         Reverts with a descriptive key on any mismatch; prints key metadata for visual inspection.
 */
contract VerifyCREWorkflow is Script {
    address internal constant CRE_WORKFLOW_REGISTRY = 0x4Ac54353FA4Fa961AfcC5ec4B118596d3305E7e5;

    error CREWorkflowWrongChain(uint256 actualChainId, uint256 expectedChainId);
    error CREWorkflowVerificationFailed(string what);

    function _requireCRE(bool ok, string memory key) private pure {
        if (!ok) revert CREWorkflowVerificationFailed(key);
    }

    /// @dev The CRE workflow owner is the LOL multisig (Safe) — the same address pinned as
    ///      `CREReceiver.expectedAuthor`. Prefer `CRE_EXPECTED_AUTHOR` (set by the recipe to the live
    ///      on-chain pin), falling back to `L2_LIQUIDITY_OWNER` for manual runs.
    function _envExpectedAuthor() internal view returns (address) {
        try vm.envAddress("CRE_EXPECTED_AUTHOR") returns (address value) {
            return value;
        } catch {
            return vm.envAddress("L2_LIQUIDITY_OWNER");
        }
    }

    function run(bytes32 workflowId) external view {
        if (block.chainid != L1.ETH_CHAIN_ID) {
            revert CREWorkflowWrongChain(block.chainid, L1.ETH_CHAIN_ID);
        }

        // zero-value guards: a registry read for id 0 returns a default-initialized struct
        // (workflowId 0, owner 0, status ACTIVE — the enum default). If `workflowId` is 0 (e.g. an
        // unchecked env read) AND `expectedAuthor` is also misconfigured to 0, all three checks below
        // would pass against a non-existent workflow — a full false-green. Reject both up-front so this
        // can only verify a real, real-owner workflow. (The justfile recipe already rejects a zero
        // workflowId; this is the on-chain defense-in-depth backstop for direct script invocations.)
        _requireCRE(workflowId != bytes32(0), "workflowId is zero");
        address expectedAuthor = _envExpectedAuthor();
        _requireCRE(expectedAuthor != address(0), "expected author is zero");

        IWorkflowRegistryV2.WorkflowMetadataView memory m =
            IWorkflowRegistryV2(CRE_WORKFLOW_REGISTRY).getWorkflowById(workflowId);

        _requireCRE(m.workflowId == workflowId, "workflow registered");
        _requireCRE(m.owner == expectedAuthor, "workflow owner");
        _requireCRE(m.status == IWorkflowRegistryV2.WorkflowStatus.ACTIVE, "workflow status");
        // a correctly-owned ACTIVE workflow can still point at a blank/stale artifact. We cannot anchor
        // the URLs to a known-good value (no expected hash on-chain), but an empty binaryUrl means the
        // workflow has no executable — assert it is populated and surface both URLs for manual review
        // (compare against the deployed binary/config out-of-band).
        _requireCRE(bytes(m.binaryUrl).length > 0, "workflow binaryUrl empty");

        console2.log("workflowId :", vm.toString(m.workflowId));
        console2.log("owner      :", m.owner);
        console2.log("status     :", "ACTIVE");
        console2.log("name       :", m.workflowName);
        console2.log("tag        :", m.tag);
        console2.log("createdAt  :", m.createdAt);
        console2.log("binaryUrl  :", m.binaryUrl);
        console2.log("configUrl  :", m.configUrl);
    }
}
