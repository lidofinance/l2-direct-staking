// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2UpgradeScriptBase} from "script/shared/L2UpgradeScriptBase.s.sol";
import {OptimismL2UpgradeScript} from "script/optimism/OptimismL2Upgrade.s.sol";
import {OptimismMigrationConstants as C} from "script/optimism/OptimismMigrationConstants.sol";

/// @dev Exposes the internal pinned-constant resolvers for unit testing.
contract OptimismPinnedHarness is OptimismL2UpgradeScript {
    function governanceExecutor() external pure returns (address) {
        return _governanceExecutor();
    }

    function oldOraclePool() external pure returns (address) {
        return _oldOraclePool();
    }

    function creForwarder() external pure returns (address) {
        return _creForwarder();
    }
}

/// @dev Unpinned-network harness: keeps the base `address(0)` defaults for every `_expected*` hook (a
///      network with no canonical values). Each resolver must REVERT rather than fall back to anything —
///      env is never consulted. Extends the abstract base directly, depending on no specific network.
contract UnpinnedHarness is L2UpgradeScriptBase {
    function _buildConfig(address, address, address) internal pure override returns (L2UpgradeConfig memory) {}
    function _defaultLiquidityOwner() internal pure override returns (address) {}
    function _expectedChainId() internal pure override returns (uint256) {}

    function governanceExecutor() external pure returns (address) {
        return _governanceExecutor();
    }

    function oldOraclePool() external pure returns (address) {
        return _oldOraclePool();
    }

    function creForwarder() external pure returns (address) {
        return _creForwarder();
    }
}

/// @notice The migration's per-network addresses — governance executor, predecessor OraclePool, and CRE
///         forwarder — are sourced ONLY from the per-network constants (cross-checked to the .inputs.yaml
///         anchors by verify-constants-sync) — NEVER from env. This removes the class of bug where a wrong
///         env value is baked into the irreversible admin handover / rollback / immutable CREReceiver (the
///         historical wrong Base/Linea executor). A network that leaves a constant unpinned reverts rather
///         than deploying / restoring a zero address. RPC-free — no broadcast/fork.
contract L2PinnedConstantsGuardTest is Test {
    OptimismPinnedHarness internal opt;
    UnpinnedHarness internal unpinned;

    function setUp() public {
        opt = new OptimismPinnedHarness();
        unpinned = new UnpinnedHarness();
    }

    /// @dev A production lane resolves every address straight from its pinned constants — no env involved.
    function test_resolvesPinnedPerNetworkConstants() public {
        assertEq(opt.governanceExecutor(), C.LIDO_L2_GOVERNANCE_EXECUTOR, "optimism governance executor");
        assertEq(opt.oldOraclePool(), C.L2_OLD_ORACLE_POOL, "optimism old oracle pool");
        assertEq(opt.creForwarder(), C.CRE_FORWARDER, "optimism cre forwarder");
    }

    /// @dev An unpinned network has no canonical value and no env fallback, so each resolver reverts
    ///      rather than silently resolving to address(0).
    function test_unpinnedNetworkReverts() public {
        vm.expectRevert(L2UpgradeScriptBase.L2UpgradeGovernanceExecutorNotPinned.selector);
        unpinned.governanceExecutor();

        vm.expectRevert(L2UpgradeScriptBase.L2UpgradeOldOraclePoolNotPinned.selector);
        unpinned.oldOraclePool();

        vm.expectRevert(L2UpgradeScriptBase.L2UpgradeCREForwarderNotPinned.selector);
        unpinned.creForwarder();
    }
}
