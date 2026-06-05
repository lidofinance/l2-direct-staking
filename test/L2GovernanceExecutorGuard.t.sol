// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2UpgradeScriptBase} from "script/shared/L2UpgradeScriptBase.s.sol";
import {OptimismL2UpgradeScript} from "script/optimism/OptimismL2Upgrade.s.sol";
import {SepoliaL2UpgradeScript} from "script/optimism/sepolia/SepoliaL2Upgrade.s.sol";
import {OptimismMigrationConstants as C} from "script/optimism/OptimismMigrationConstants.sol";

/// @dev Exposes the internal env/gov-executor guard for unit testing.
contract OptimismGuardHarness is OptimismL2UpgradeScript {
    function envGovernanceExecutor() external view returns (address) {
        return _envGovernanceExecutor();
    }

    function expectedGovernanceExecutor() external pure returns (address) {
        return _expectedGovernanceExecutor();
    }
}

contract SepoliaGuardHarness is SepoliaL2UpgradeScript {
    function envGovernanceExecutor() external view returns (address) {
        return _envGovernanceExecutor();
    }

    function expectedGovernanceExecutor() external pure returns (address) {
        return _expectedGovernanceExecutor();
    }
}

/// @notice FINDINGS.md F-4: `L2_GOVERNANCE_EXECUTOR` must be validated against the per-network
///         known-correct executor before any irreversible admin/ownership handover. A wrong-but-
///         nonzero value previously had no on-chain guardrail (the historical wrong Base/Linea
///         executor). RPC-free — exercises only the env guard, not the broadcast/fork paths.
contract L2GovernanceExecutorGuardTest is Test {
    OptimismGuardHarness internal opt;
    SepoliaGuardHarness internal sep;

    function setUp() public {
        opt = new OptimismGuardHarness();
        sep = new SepoliaGuardHarness();
    }

    function test_expectedExecutor_perNetwork() public {
        // Mainnet pins the per-network constant; Sepolia opts out (no canonical executor).
        assertEq(opt.expectedGovernanceExecutor(), C.LIDO_L2_GOVERNANCE_EXECUTOR, "optimism expected");
        assertEq(sep.expectedGovernanceExecutor(), address(0), "sepolia opt-out");
    }

    /// @dev Every env-dependent assertion lives in THIS single method on purpose: `vm.setEnv` mutates
    ///      process-global state, so splitting these across test methods races under forge's parallel
    ///      execution. Sequenced within one method, the reads are deterministic.
    function test_envGovernanceExecutor_validatesAgainstConstant() public {
        // Correct value → accepted (mainnet).
        vm.setEnv("L2_GOVERNANCE_EXECUTOR", vm.toString(C.LIDO_L2_GOVERNANCE_EXECUTOR));
        assertEq(opt.envGovernanceExecutor(), C.LIDO_L2_GOVERNANCE_EXECUTOR, "correct executor accepted");

        // Wrong-but-nonzero value → reverts (mainnet). This is the F-4 guard the historical bug needed.
        address wrong = makeAddr("wrongExecutor");
        vm.setEnv("L2_GOVERNANCE_EXECUTOR", vm.toString(wrong));
        vm.expectRevert(
            abi.encodeWithSelector(
                L2UpgradeScriptBase.L2UpgradeWrongGovernanceExecutor.selector, wrong, C.LIDO_L2_GOVERNANCE_EXECUTOR
            )
        );
        opt.envGovernanceExecutor();

        // Sepolia opts out → the same "wrong" value passes through (operator-supplied, no canonical value).
        assertEq(sep.envGovernanceExecutor(), wrong, "sepolia accepts any nonzero executor");
    }
}
