// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {ISyncTrigger} from "src/interfaces/ISyncTrigger.sol";

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
    address internal creForwarder = makeAddr("creForwarder");
    address internal creAuthor = makeAddr("creWorkflowAuthor");

    function test_creReceiverTriggersSyncViaReport() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);

        vm.warp(block.timestamp + L2_SYNC_DELAY);

        (bool syncNeeded, uint256 amount) = syncTrigger.shouldSync();
        assertTrue(syncNeeded, "sync should be needed");
        assertGt(amount, 0, "sync amount should be > 0");

        vm.deal(address(syncTrigger), 1 ether);

        bytes memory callData = abi.encodeCall(ISyncTrigger.triggerSync, ());
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
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndSetupCRE();

        address newAuthor = makeAddr("rotatedAuthor");
        creReceiver.setExpectedAuthor(newAuthor);

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        vm.deal(address(syncTrigger), 1 ether);
        bytes memory report = abi.encode(address(syncTrigger), abi.encodeCall(ISyncTrigger.triggerSync, ()));

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

    function test_creReceiverRejectsDisallowedTarget() public {
        (, ISyncTrigger syncTrigger) = _deployAndSetupCRE();

        address other = makeAddr("rogueTarget");
        bytes memory report = abi.encode(other, abi.encodeCall(ISyncTrigger.triggerSync, ()));

        vm.prank(creForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                CREReceiver.CallNotAllowed.selector, other, ISyncTrigger.triggerSync.selector
            )
        );
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);

        // Silence unused variable warning.
        syncTrigger;
    }

    function test_crePathRespectsDelay() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);

        (bool syncNeeded,) = syncTrigger.shouldSync();
        assertFalse(syncNeeded, "sync should not be needed before delay");

        vm.warp(block.timestamp + L2_SYNC_DELAY);
        (syncNeeded,) = syncTrigger.shouldSync();
        assertTrue(syncNeeded, "sync should be needed after delay");
    }

    function test_crePathRespectsMinAmount() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 belowMin = uint256(L2_SYNC_MIN_AMOUNT) - 1;
        _provisionPoolAndAccumulateWeth(newPool, belowMin);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        (bool syncNeeded,) = syncTrigger.shouldSync();
        assertFalse(syncNeeded, "sync should not trigger below min");
    }

    function test_crePathCapsAtMaxAmount() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndSetupCRE();

        deal(L2_WETH, address(newPool), uint256(L2_SYNC_MAX_AMOUNT) + 50 ether);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        (, uint256 amount) = syncTrigger.shouldSync();
        assertEq(amount, uint256(L2_SYNC_MAX_AMOUNT), "should cap at max");

        // Silence unused variable warning.
        newPool;
    }

    function test_syncTriggerRejectsDirectCallAfterCRESetup() public {
        (, ISyncTrigger syncTrigger) = _deployAndSetupCRE();

        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        vm.expectRevert(ISyncTrigger.SyncTriggerOnlyForwarder.selector);
        syncTrigger.triggerSync();
    }

    function test_creUpdatesLastExecutionAfterTrigger() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndSetupCRE();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        (bool syncNeeded,) = syncTrigger.shouldSync();
        assertTrue(syncNeeded, "sync should be needed before trigger");

        uint48 lastExecBefore = syncTrigger.getLastExecution();
        vm.deal(address(syncTrigger), 1 ether);

        bytes memory report = abi.encode(
            address(syncTrigger), abi.encodeCall(ISyncTrigger.triggerSync, ())
        );
        vm.prank(creForwarder);
        creReceiver.onReport(_buildCREMetadata(creAuthor), report);

        assertEq(syncTrigger.getLastExecution(), uint48(block.timestamp), "lastExecution should update");
        assertGt(syncTrigger.getLastExecution(), lastExecBefore, "lastExecution should advance");
    }

    function _deployAndSetupCRE()
        internal
        returns (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger)
    {
        address syncTriggerAddr;
        (newPool, syncTriggerAddr) = _deployAndMigrateL2WithSyncTrigger();
        syncTrigger = ISyncTrigger(syncTriggerAddr);

        creReceiver = new CREReceiver(
            creForwarder,
            creAuthor,
            syncTriggerAddr,
            ISyncTrigger.triggerSync.selector
        );

        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        syncTrigger.setForwarder(address(creReceiver));
        assertEq(syncTrigger.getForwarder(), address(creReceiver), "forwarder should be CREReceiver");
    }

    /// @dev Builds CRE metadata: abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    function _buildCREMetadata(address workflowOwner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32("lido-sync"), bytes10("lidosync"), workflowOwner);
    }
}
