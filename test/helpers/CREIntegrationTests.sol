// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {SyncTrigger} from "src/SyncTrigger.sol";

import {CREReceiver} from "src/cre/CREReceiver.sol";
import {UpgradeTestBase} from "test/helpers/UpgradeTestBase.sol";

/**
 * @title CREIntegrationTests
 * @notice Shared CRE integration test logic, network-agnostic.
 * @dev Subclasses populate state via their network-specific UpgradeTestBase.
 *      Same pattern as PoolUpgradeTests.sol.
 */
abstract contract CREIntegrationTests is UpgradeTestBase {
    CREReceiver internal creReceiver;
    // creForwarder is inherited from UpgradeTestBase (the address the on-fork handoff wires in);
    // creAuthor is set by _deployAndSetupCRE to the LOL multisig the handoff pins as expectedAuthor.
    address internal creAuthor;

    function test_creReceiverTriggersSyncViaReport() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);

        vm.warp(block.timestamp + L2_SYNC_DELAY);

        // Fund the float so canSync (executability) holds; the migration already granted SYNC_ROLE.
        vm.deal(address(syncTrigger), 1 ether);

        assertGt(syncTrigger.shouldSyncAmount(), 0, "sync should be due (amount > 0)");
        assertTrue(syncTrigger.canSync(), "sync should be executable");

        bytes memory callData = abi.encodeCall(SyncTrigger.triggerSync, ());
        bytes memory report = abi.encode(address(syncTrigger), callData);

        uint256 poolWethBefore = IERC20(L2_WETH).balanceOf(address(newPool));

        vm.prank(creForwarder);
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);

        uint256 expectedSync = stakeAmount > uint256(L2_SYNC_MAX_AMOUNT) ? L2_SYNC_MAX_AMOUNT : stakeAmount;
        assertEq(
            IERC20(L2_WETH).balanceOf(address(newPool)),
            poolWethBefore - expectedSync,
            "pool WETH should decrease by synced amount"
        );
    }

    function test_creReceiverRespectsOnlyForwarder() public {
        _deployAndSetupCRE();

        bytes memory report = abi.encode(address(1), hex"");

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(CREReceiver.UnauthorizedForwarder.selector, attacker, creForwarder)
        );
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);
    }

    function test_creReceiverRotatesExpectedAuthor() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        address newAuthor = makeAddr("rotatedAuthor");
        // The bound receiver is LOL-owned after the on-fork handoff, so the rotation is a LOL action.
        vm.prank(lidoL2LiquidityOwner);
        creReceiver.setExpectedAuthor(newAuthor);

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        vm.deal(address(syncTrigger), 1 ether);
        bytes memory report = abi.encode(address(syncTrigger), abi.encodeCall(SyncTrigger.triggerSync, ()));

        // Old author is now rejected.
        vm.prank(creForwarder);
        vm.expectRevert(abi.encodeWithSelector(CREReceiver.InvalidAuthor.selector, creAuthor, newAuthor));
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);

        // New author is accepted.
        vm.prank(creForwarder);
        creReceiver.onReport(_buildCREMetadata(newAuthor), report);

        assertLt(
            IERC20(L2_WETH).balanceOf(address(newPool)),
            uint256(L2_SYNC_MIN_AMOUNT) + 1 ether,
            "pool WETH should decrease after CRE-triggered sync"
        );
    }

    /// @notice The production deploy path pins `expectedAuthor` to the LOL multisig (Safe) — NOT the
    ///         Lido Deployer EOA — so the CRE workflow owner, the `expectedAuthor` pin, and the
    ///         CREReceiver owner are all the same Safe address (ADR-0001 / DOC.md §3.2). A report
    ///         authored by the Safe is accepted; one authored by the deployer EOA is rejected.
    function test_productionExpectedAuthorIsLolMultisig() public {
        (PausableImmutableOraclePool newPool, address newSyncTrigger, CREReceiver prodReceiver) =
            _deployAndMigrateL2Production();

        // Invariant: workflow owner == expectedAuthor == CREReceiver owner == the LOL multisig.
        assertEq(prodReceiver.getExpectedAuthor(), lidoL2LiquidityOwner, "expectedAuthor must be LOL multisig");
        assertEq(Ownable(address(prodReceiver)).owner(), lidoL2LiquidityOwner, "CREReceiver owner must be LOL multisig");
        // It must NOT be the Stage-1 broadcaster (the deployer EOA used inside the production path).
        assertTrue(prodReceiver.getExpectedAuthor() != lidoStage1Deployer, "expectedAuthor must not be the deployer EOA");

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        // Production wiring sets the SyncTrigger forwarder to the CREReceiver. The migration hands the
        // trigger over drained (handoff sweeps the float), so fund it here — the post-migration
        // `fund-trigger` operational step.
        vm.deal(newSyncTrigger, 1 ether);
        bytes memory report = abi.encode(newSyncTrigger, abi.encodeCall(SyncTrigger.triggerSync, ()));

        // A report authored by the Lido Deployer EOA (a plausible mis-pin / stale workflow) is rejected.
        vm.prank(prodReceiver.getForwarder());
        vm.expectRevert(
            abi.encodeWithSelector(CREReceiver.InvalidAuthor.selector, lidoStage1Deployer, lidoL2LiquidityOwner)
        );
        prodReceiver.onReport(_buildCREMetadata(lidoStage1Deployer), report);

        // A report authored by the LOL multisig (Safe) is accepted and drives the sync.
        uint256 poolWethBefore = IERC20(L2_WETH).balanceOf(address(newPool));
        vm.prank(prodReceiver.getForwarder());
        prodReceiver.onReport(_buildCREMetadata(lidoL2LiquidityOwner), report);
        assertLt(
            IERC20(L2_WETH).balanceOf(address(newPool)),
            poolWethBefore,
            "pool WETH should decrease after Safe-authored CRE sync"
        );
    }

    function test_creReceiverRejectsDisallowedTarget() public {
        (, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        address other = makeAddr("rogueTarget");
        bytes memory report = abi.encode(other, abi.encodeCall(SyncTrigger.triggerSync, ()));

        vm.prank(creForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CREReceiver.CallNotAllowed.selector, other, SyncTrigger.triggerSync.selector
            )
        );
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);

        // Silence unused variable warning.
        syncTrigger;
    }

    function test_crePathRespectsDelay() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        // shouldSyncAmount is the due-ness + amount signal (delay + pool >= min); no float needed for it.

        assertEq(syncTrigger.shouldSyncAmount(), 0, "sync should not be due before delay");

        vm.warp(block.timestamp + L2_SYNC_DELAY);
        assertGt(syncTrigger.shouldSyncAmount(), 0, "sync should be due after delay");
    }

    function test_crePathRespectsMinAmount() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 belowMin = uint256(L2_SYNC_MIN_AMOUNT) - 1;
        _provisionPoolAndAccumulateWeth(newPool, belowMin);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        assertEq(syncTrigger.shouldSyncAmount(), 0, "sync should not trigger below min");
    }

    function test_crePathCapsAtMaxAmount() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        deal(L2_WETH, address(newPool), uint256(L2_SYNC_MAX_AMOUNT) + 50 ether);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        assertEq(syncTrigger.shouldSyncAmount(), uint256(L2_SYNC_MAX_AMOUNT), "should cap at max");

        // Silence unused variable warning.
        newPool;
    }

    function test_syncTriggerRejectsDirectCallAfterCRESetup() public {
        (, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        vm.expectRevert(SyncTrigger.SyncTriggerOnlyForwarder.selector);
        syncTrigger.triggerSync();
    }

    function test_creUpdatesLastExecutionAfterTrigger() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        vm.warp(block.timestamp + L2_SYNC_DELAY);
        vm.deal(address(syncTrigger), 1 ether); // fund float so the CRE triggerSync can pay

        assertGt(syncTrigger.shouldSyncAmount(), 0, "sync should be due before trigger");

        uint48 lastExecBefore = syncTrigger.getLastExecution();

        bytes memory report = abi.encode(
            address(syncTrigger), abi.encodeCall(SyncTrigger.triggerSync, ())
        );
        vm.prank(creForwarder);
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);

        assertEq(syncTrigger.getLastExecution(), uint48(block.timestamp), "lastExecution should update");
        assertGt(syncTrigger.getLastExecution(), lastExecBefore, "lastExecution should advance");
    }

    /// @notice Cross-checks that canSync() tracks real on-chain executability for the fee-float case
    ///         (the most material stall in LOW-2): below getMaxFees().maxNativeFee canSync is false AND
    ///         triggerSync reverts with the named SyncTriggerInsufficientFloat; at the float canSync is
    ///         true AND the CRE-driven sync succeeds. shouldSyncAmount (due-ness) stays nonzero throughout.
    function test_canSyncTracksFloatExecutability() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        uint256 amount = syncTrigger.shouldSyncAmount();
        assertGt(amount, 0, "a sync is due");

        uint256 maxNativeFee = syncTrigger.getMaxFees();
        assertGt(maxNativeFee, 0, "native-fee lane");

        // One wei short of the float: canSync false (blocked), but the need is still reported and due.
        vm.deal(address(syncTrigger), maxNativeFee - 1);
        assertFalse(syncTrigger.canSync(), "canSync false below the float");
        assertEq(syncTrigger.shouldSyncAmount(), amount, "still due, still reports the need (stall, not no-op)");

        // The chain agrees: triggerSync reverts with the named float error. Called directly as the
        // forwarder (CREReceiver) to read the RAW error — via onReport the receiver wraps it in
        // CallExecutionFailed, so the named selector is the inner returndata.
        bytes memory report = abi.encode(address(syncTrigger), abi.encodeCall(SyncTrigger.triggerSync, ()));
        vm.prank(address(creReceiver));
        vm.expectRevert(
            abi.encodeWithSelector(SyncTrigger.SyncTriggerInsufficientFloat.selector, maxNativeFee, maxNativeFee - 1)
        );
        syncTrigger.triggerSync();

        // At exactly the float: canSync true, and the CRE sync now drains the pool.
        vm.deal(address(syncTrigger), maxNativeFee);
        assertTrue(syncTrigger.canSync(), "canSync true at the float");

        uint256 poolWethBefore = IERC20(L2_WETH).balanceOf(address(newPool));
        vm.prank(creForwarder);
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);
        assertLt(IERC20(L2_WETH).balanceOf(address(newPool)), poolWethBefore, "sync drained pool WETH");
    }

    /// @notice Pausing the OraclePool (a documented kill switch, DOC §3.4) flips canSync() to false so
    ///         the DON halts cleanly, and the chain agrees: the CRE-driven triggerSync reverts.
    function test_canSyncFalseWhenPoolPaused() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        uint256 maxNativeFee = syncTrigger.getMaxFees();
        vm.deal(address(syncTrigger), maxNativeFee);

        assertTrue(syncTrigger.canSync(), "canSync true while unpaused + funded");

        vm.prank(Ownable(address(newPool)).owner());
        newPool.pause();

        assertFalse(syncTrigger.canSync(), "canSync false when pool paused");
        assertGt(syncTrigger.shouldSyncAmount(), 0, "still due, need still reported while blocked");

        // The chain agrees: pull() is whenNotPaused, so the CRE-driven sync reverts.
        bytes memory report = abi.encode(address(syncTrigger), abi.encodeCall(SyncTrigger.triggerSync, ()));
        vm.prank(creForwarder);
        vm.expectRevert();
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);
    }

    /// @dev Bind to the DEPLOYED canary and drive it to the sealed production end state
    ///      ({_deployAndMigrateL2Canary}), then adopt the deployed CREReceiver instead of deploying a
    ///      fresh one. The handoff/finalize interlocks already assert the wiring (trigger forwarder =
    ///      receiver, receiver forwarder = {creForwarder}, expectedAuthor = LOL), so no re-checks here.
    function _deployAndSetupCRE()
        internal
        returns (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger)
    {
        address syncTriggerAddr;
        (newPool, syncTriggerAddr, creReceiver) = _deployAndMigrateL2Canary();
        syncTrigger = SyncTrigger(payable(syncTriggerAddr));
        creAuthor = lidoL2LiquidityOwner;
    }

    /// @dev Builds CRE metadata: abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    function _buildCREMetadata(address workflowOwner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32("lido-sync"), bytes10("lidosync"), workflowOwner);
    }
}
