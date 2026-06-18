// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {L2UpgradeScriptBase} from "script/shared/L2UpgradeScriptBase.s.sol";
import {OptimismL2UpgradeScript} from "script/optimism/OptimismL2Upgrade.s.sol";
import {SepoliaL2UpgradeScript} from "script/optimism/sepolia/SepoliaL2Upgrade.s.sol";
import {OptimismMigrationConstants as C} from "script/optimism/OptimismMigrationConstants.sol";

/// @dev Exposes the internal CRE-forwarder resolver/pin for unit testing.
contract OptimismForwarderGuardHarness is OptimismL2UpgradeScript {
    function creForwarder() external view returns (address) {
        return _creForwarder();
    }

    function expectedCREForwarder() external pure returns (address) {
        return _expectedCREForwarder();
    }

    function resolvePinned(string calldata envName, address expected) external view returns (address, bool) {
        return _resolvePinned(envName, expected);
    }
}

contract SepoliaForwarderGuardHarness is SepoliaL2UpgradeScript {
    function creForwarder() external view returns (address) {
        return _creForwarder();
    }

    function expectedCREForwarder() external pure returns (address) {
        return _expectedCREForwarder();
    }
}

/// @notice The Chainlink CRE Forwarder is a fixed, Chainlink-published per-network address, so
///         production networks pin it in code (CRE_FORWARDER) instead of reading `L2_CRE_FORWARDER`.
///         `_creForwarder()` therefore defaults to the pin and rejects a present-but-wrong env value:
///         a stale/mistyped forwarder must never be baked IMMUTABLY into CREReceiver (every
///         CRE-triggered sync would then be silently rejected by the real forwarder). Sepolia opts out
///         (no canonical forwarder) and supplies it via env as before. RPC-free — exercises only the
///         resolver, not the broadcast/fork paths.
contract L2CREForwarderGuardTest is Test {
    OptimismForwarderGuardHarness internal opt;
    SepoliaForwarderGuardHarness internal sep;

    function setUp() public {
        opt = new OptimismForwarderGuardHarness();
        sep = new SepoliaForwarderGuardHarness();
    }

    function test_expectedForwarder_perNetwork() public {
        // Mainnet pins the Chainlink-published per-network forwarder; Sepolia opts out.
        assertEq(opt.expectedCREForwarder(), C.CRE_FORWARDER, "optimism pinned forwarder");
        assertEq(sep.expectedCREForwarder(), address(0), "sepolia opt-out");
    }

    /// @dev Env-dependent assertions share ONE method on purpose: `vm.setEnv` mutates process-global
    ///      state, so splitting them races under forge's parallel execution (mirrors the sibling
    ///      L2GovernanceExecutorGuardTest note). Sequenced here, the reads are deterministic.
    function test_creForwarder_pinnedAndValidated() public {
        // Mainnet: an explicit env equal to the pin is accepted and returns the pin. When the env is
        // unset, `_creForwarder` returns this same pin via vm.envOr's default — that is the non-env
        // path (the forwarder is a network constant, not an operator input).
        vm.setEnv("L2_CRE_FORWARDER", vm.toString(C.CRE_FORWARDER));
        assertEq(opt.creForwarder(), C.CRE_FORWARDER, "matching env accepted, returns pin");

        // Mainnet: a present-but-wrong env must NOT silently override the immutable pin — it reverts.
        address wrong = makeAddr("wrongForwarder");
        vm.setEnv("L2_CRE_FORWARDER", vm.toString(wrong));
        vm.expectRevert(
            abi.encodeWithSelector(L2UpgradeScriptBase.L2UpgradeWrongCREForwarder.selector, wrong, C.CRE_FORWARDER)
        );
        opt.creForwarder();

        // Sepolia opts out → the forwarder is operator-supplied, so the same value passes through.
        assertEq(sep.creForwarder(), wrong, "sepolia reads env forwarder");
    }

    /// @dev The env-ABSENT branch — `_resolvePinned` defaults to the pin when the env var is unset — is
    ///      the path production deploy-stage1 takes when `L2_CRE_FORWARDER` is omitted (the forwarder is
    ///      a network constant, not an operator input). The sibling set-env assertions above can NEVER
    ///      reach it: this forge-std has no `unsetEnv`/`envExists`, and `vm.setEnv` is process-global and
    ///      sticky. So we drive the branch with a GUARANTEED-unset env NAME — nothing in the suite sets
    ///      it, so `vm.envOr` genuinely takes its default. This is the regression guard the set-env tests
    ///      cannot give: if `_resolvePinned` regressed from `vm.envOr(..., expected)` back to
    ///      `vm.envAddress(...)` (re-making the value env-REQUIRED, undoing deploy-stage1's removed `:?`
    ///      guard), the unset name would make it REVERT instead of returning the pin. Using a sentinel
    ///      name (not `L2_CRE_FORWARDER`) also keeps this test free of the process-global env race.
    function test_resolvePinned_defaultsToPinWhenEnvAbsent() public {
        address pin = makeAddr("pinnedConstant");
        (address resolved, bool ok) = opt.resolvePinned("L2_CRE_FORWARDER_GUARANTEED_UNSET_SENTINEL", pin);
        assertEq(resolved, pin, "absent env -> defaults to the pin (env-OPTIONAL, not env-required)");
        assertTrue(ok, "default-to-pin is a match, never a mismatch");
    }
}
