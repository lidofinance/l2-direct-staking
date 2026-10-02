// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {SyncTrigger} from "src/SyncTrigger.sol";

import {CREReceiver} from "src/cre/CREReceiver.sol";
import {PoolTestBase} from "test/helpers/PoolTestBase.sol";

/**
 * @title CREIntegrationTests
 * @notice Shared CRE integration test logic, network-agnostic.
 * @dev Subclasses populate state via their network-specific PoolTestBase.
 *      Same pattern as PoolTests.sol.
 */
abstract contract CREIntegrationTests is PoolTestBase {
    CREReceiver internal creReceiver;
    address internal creAuthor;

    function test_creReceiverTriggersSyncViaReport() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _createCREFixture();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);

        vm.warp(block.timestamp + L2_SYNC_DELAY);

        // Fund the float so canSync (executability) holds; the fixture grants SYNC_ROLE.
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
        _createCREFixture();

        bytes memory report = abi.encode(address(1), hex"");

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CREReceiver.UnauthorizedForwarder.selector, attacker, creForwarder));
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);
    }

    function test_creReceiverRotatesExpectedAuthor() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _createCREFixture();

        address newAuthor = makeAddr("rotatedAuthor");
        // Only the automation owner can rotate the report author.
        vm.prank(automationOwner);
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

    /// @notice The automation owner authors reports; the liquidity owner has no report authority.
    function test_onlyAutomationOwnerAuthorsReports() public {
        (PausableImmutableOraclePool newPool, address newSyncTrigger, CREReceiver prodReceiver) = _createL2Fixture();

        // Invariant: workflow owner == expectedAuthor == CREReceiver owner == the automation owner.
        assertEq(prodReceiver.getExpectedAuthor(), automationOwner, "expectedAuthor must be automation owner");
        assertEq(Ownable(address(prodReceiver)).owner(), automationOwner, "CREReceiver owner must be automation owner");
        // It must NOT be the liquidity owner.
        assertTrue(
            prodReceiver.getExpectedAuthor() != lidoL2LiquidityOwner, "expectedAuthor must not be the liquidity owner"
        );

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        // Fund the trigger so the accepted report can pay for a sync.
        vm.deal(newSyncTrigger, 1 ether);
        bytes memory report = abi.encode(newSyncTrigger, abi.encodeCall(SyncTrigger.triggerSync, ()));

        // A report authored by the liquidity owner (a plausible mis-pin / stale workflow) is rejected.
        vm.prank(prodReceiver.getForwarder());
        vm.expectRevert(
            abi.encodeWithSelector(CREReceiver.InvalidAuthor.selector, lidoL2LiquidityOwner, automationOwner)
        );
        prodReceiver.onReport(_buildCREMetadata(lidoL2LiquidityOwner), report);

        // A report authored by the automation owner (Safe) is accepted and drives the sync.
        uint256 poolWethBefore = IERC20(L2_WETH).balanceOf(address(newPool));
        vm.prank(prodReceiver.getForwarder());
        prodReceiver.onReport(_buildCREMetadata(automationOwner), report);
        assertLt(
            IERC20(L2_WETH).balanceOf(address(newPool)),
            poolWethBefore,
            "pool WETH should decrease after Safe-authored CRE sync"
        );
    }

    function test_creReceiverRejectsDisallowedTarget() public {
        _createCREFixture();

        address other = makeAddr("rogueTarget");
        bytes memory report = abi.encode(other, abi.encodeCall(SyncTrigger.triggerSync, ()));

        vm.prank(creForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(CREReceiver.CallNotAllowed.selector, other, SyncTrigger.triggerSync.selector)
        );
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);
    }

    function test_crePathRespectsDelay() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _createCREFixture();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        // shouldSyncAmount is the due-ness + amount signal (delay + pool >= min); no float needed for it.

        assertEq(syncTrigger.shouldSyncAmount(), 0, "sync should not be due before delay");

        vm.warp(block.timestamp + L2_SYNC_DELAY);
        assertGt(syncTrigger.shouldSyncAmount(), 0, "sync should be due after delay");
    }

    function test_crePathRespectsMinAmount() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _createCREFixture();

        uint256 belowMin = uint256(L2_SYNC_MIN_AMOUNT) - 1;
        _provisionPoolAndAccumulateWeth(newPool, belowMin);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        assertEq(syncTrigger.shouldSyncAmount(), 0, "sync should not trigger below min");
    }

    function test_crePathCapsAtMaxAmount() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _createCREFixture();

        deal(L2_WETH, address(newPool), uint256(L2_SYNC_MAX_AMOUNT) + 50 ether);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        assertEq(syncTrigger.shouldSyncAmount(), uint256(L2_SYNC_MAX_AMOUNT), "should cap at max");
    }

    function test_syncTriggerRejectsDirectCallAfterCRESetup() public {
        (, SyncTrigger syncTrigger) = _createCREFixture();

        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        vm.expectRevert(SyncTrigger.SyncTriggerOnlyForwarder.selector);
        syncTrigger.triggerSync();
    }

    function test_creUpdatesLastExecutionAfterTrigger() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _createCREFixture();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        vm.warp(block.timestamp + L2_SYNC_DELAY);
        vm.deal(address(syncTrigger), 1 ether); // fund float so the CRE triggerSync can pay

        assertGt(syncTrigger.shouldSyncAmount(), 0, "sync should be due before trigger");

        uint48 lastExecBefore = syncTrigger.getLastExecution();

        bytes memory report = abi.encode(address(syncTrigger), abi.encodeCall(SyncTrigger.triggerSync, ()));
        vm.prank(creForwarder);
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);

        assertEq(syncTrigger.getLastExecution(), uint48(block.timestamp), "lastExecution should update");
        assertGt(syncTrigger.getLastExecution(), lastExecBefore, "lastExecution should advance");
    }

    /// @notice Cross-checks that canSync() tracks real on-chain executability for the fee-float case
    ///         below getMaxFees() canSync is false AND
    ///         triggerSync reverts with the named SyncTriggerInsufficientFloat; at the float canSync is
    ///         true AND the CRE-driven sync succeeds. shouldSyncAmount (due-ness) stays nonzero throughout.
    function test_canSyncTracksFloatExecutability() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _createCREFixture();

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

    /// @notice Pausing the OraclePool (a documented kill switch, DOC.md, Ownership and access control) flips canSync() to false so
    ///         the DON halts cleanly, and the chain agrees: the CRE-driven triggerSync reverts.
    function test_canSyncFalseWhenPoolPaused() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _createCREFixture();

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

    /// @dev Use the current ownership model and wire reports through the fixture receiver.
    function _createCREFixture() internal returns (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) {
        address syncTriggerAddr;
        (newPool, syncTriggerAddr, creReceiver) = _createL2Fixture();
        syncTrigger = SyncTrigger(payable(syncTriggerAddr));
        creAuthor = automationOwner;
    }

    /// @dev Builds CRE metadata: abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    function _buildCREMetadata(address workflowOwner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32("lido-sync"), bytes10("lidosync"), workflowOwner);
    }
}
