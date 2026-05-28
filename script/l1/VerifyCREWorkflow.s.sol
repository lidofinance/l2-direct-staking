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
 *         Required env: either `L2_LIDO_DEPLOYER_ADDRESS` or `L2_LIDO_DEPLOYER_PRIVATE_KEY`
 *         (the address pinned as the CRE workflow's owner and `CREReceiver.expectedAuthor`).
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

    function _envExpectedAuthor() internal view returns (address) {
        try vm.envAddress("L2_LIDO_DEPLOYER_ADDRESS") returns (address value) {
            return value;
        } catch {
            return vm.addr(vm.envUint("L2_LIDO_DEPLOYER_PRIVATE_KEY"));
        }
    }

    function run(bytes32 workflowId) external view {
        if (block.chainid != L1.ETH_CHAIN_ID) {
            revert CREWorkflowWrongChain(block.chainid, L1.ETH_CHAIN_ID);
        }

        address expectedAuthor = _envExpectedAuthor();

        IWorkflowRegistryV2.WorkflowMetadataView memory m =
            IWorkflowRegistryV2(CRE_WORKFLOW_REGISTRY).getWorkflowById(workflowId);

        _requireCRE(m.workflowId == workflowId, "workflow registered");
        _requireCRE(m.owner == expectedAuthor, "workflow owner");
        _requireCRE(m.status == IWorkflowRegistryV2.WorkflowStatus.ACTIVE, "workflow status");

        console2.log("workflowId :", vm.toString(m.workflowId));
        console2.log("owner      :", m.owner);
        console2.log("status     :", "ACTIVE");
        console2.log("name       :", m.workflowName);
        console2.log("tag        :", m.tag);
        console2.log("createdAt  :", m.createdAt);
    }
}
