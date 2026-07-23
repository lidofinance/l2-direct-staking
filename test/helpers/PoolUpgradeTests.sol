// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PausableImmutableOraclePool} from "@csr/utils/PausableImmutableOraclePool.sol";
import {ICustomSender} from "@csr/interfaces/ICustomSender.sol";
import {ICustomReceiver} from "@csr/interfaces/ICustomReceiver.sol";
import {IOraclePool} from "@csr/interfaces/IOraclePool.sol";
import {FeeCodec} from "@csr/libraries/FeeCodec.sol";
import {SyncTrigger} from "src/SyncTrigger.sol";
import {CREReceiver} from "src/cre/CREReceiver.sol";

import {UpgradeTestBase, MockBridgeAdapter} from "test/helpers/UpgradeTestBase.sol";

/**
 * @title PoolUpgradeTests
 * @notice Shared pool upgrade test functions for all networks.
 * @dev Extends UpgradeTestBase and uses its state variables.
 *      Concrete test contracts combine a network-specific base with this mixin:
 *        contract OptimismPoolUpgradeTest is OptimismUpgradeTestBase, PoolUpgradeTests {}
 */
abstract contract PoolUpgradeTests is UpgradeTestBase {
    function test_migrateL2() public {
        (PausableImmutableOraclePool newPool, address newSyncTrigger) = _deployAndMigrateL2WithSyncTrigger();

        address impl = address(uint160(uint256(vm.load(L2_CUSTOM_SENDER, EIP1967_IMPL_SLOT))));
        assertEq(impl, L2_CUSTOM_SENDER_IMPL, "L2 proxy implementation should be unchanged");

        address proxyAdmin = address(uint160(uint256(vm.load(L2_CUSTOM_SENDER, EIP1967_ADMIN_SLOT))));
        assertEq(proxyAdmin, L2_PROXY_ADMIN, "L2 proxy admin slot should be unchanged");

        assertEq(ICustomSender(L2_CUSTOM_SENDER).TOKEN(), L2_WETH, "L2 sender TOKEN");
        assertEq(ICustomSender(L2_CUSTOM_SENDER).WNATIVE(), L2_WETH, "L2 sender WNATIVE");
        assertEq(ICustomSender(L2_CUSTOM_SENDER).CCIP_ROUTER(), L2_CCIP_ROUTER, "L2 sender CCIP_ROUTER");
        assertEq(ICustomSender(L2_CUSTOM_SENDER).LINK_TOKEN(), L2_LINK_TOKEN, "L2 sender LINK_TOKEN");

        assertEq(
            ICustomSender(L2_CUSTOM_SENDER).getOraclePool(),
            address(newPool),
            "L2 sender oraclePool should point to new pool"
        );

        bytes memory receiver = ICustomSender(L2_CUSTOM_SENDER).getReceiver(ETH_CCIP_CHAIN_SELECTOR);
        assertEq(
            receiver,
            abi.encode(L1_LIDO_CUSTOM_RECEIVER),
            "L2 sender receiver for ETH should still be L1 LidoCustomReceiver"
        );

        assertTrue(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(DEFAULT_ADMIN_ROLE, LIDO_L2_GOVERNANCE_EXECUTOR),
            "L2 sender: LIDO_L2_GOVERNANCE_EXECUTOR should have DEFAULT_ADMIN_ROLE"
        );
        assertFalse(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(DEFAULT_ADMIN_ROLE, lidoL2LiquidityOwner),
            "L2 sender: liquidity owner should not have DEFAULT_ADMIN_ROLE"
        );
        assertFalse(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(DEFAULT_ADMIN_ROLE, INITIAL_OWNER),
            "L2 sender: INITIAL_OWNER should not have DEFAULT_ADMIN_ROLE"
        );

        assertEq(Ownable(L2_PROXY_ADMIN).owner(), LIDO_L2_GOVERNANCE_EXECUTOR, "L2 ProxyAdmin owner");

        _verifyOldAutomationsRevoked();

        assertEq(newPool.SENDER(), L2_CUSTOM_SENDER, "new pool SENDER");
        assertEq(newPool.TOKEN_IN(), L2_WETH, "new pool TOKEN_IN");
        assertEq(newPool.TOKEN_OUT(), L2_WSTETH, "new pool TOKEN_OUT");
        assertEq(newPool.getOracle(), L2_PRICE_ORACLE, "new pool oracle");
        assertEq(newPool.getFee(), 0, "new pool fee");
        assertEq(newPool.owner(), lidoL2LiquidityOwner, "new pool owner");
        assertFalse(newPool.paused(), "new pool should not be paused");

        _verifySyncTriggerConfig(newSyncTrigger);
    }

    function test_fastStakeAfterMigration() public {
        PausableImmutableOraclePool newPool = _deployAndMigrateL2();
        deal(L2_WSTETH, address(newPool), 100 ether);

        address user = makeAddr("user");
        uint256 stakeAmount = 1 ether;
        deal(L2_WETH, user, stakeAmount);

        uint256 poolWstBefore = IERC20(L2_WSTETH).balanceOf(address(newPool));
        uint256 poolWethBefore = IERC20(L2_WETH).balanceOf(address(newPool));

        vm.startPrank(user);
        IERC20(L2_WETH).approve(L2_CUSTOM_SENDER, stakeAmount);
        uint256 amountOut = ICustomSender(L2_CUSTOM_SENDER).fastStake(L2_WETH, stakeAmount, 0);
        vm.stopPrank();

        assertGt(amountOut, 0, "amountOut should be > 0");
        assertEq(IERC20(L2_WSTETH).balanceOf(user), amountOut, "user wstETH balance mismatch");
        assertEq(
            IERC20(L2_WSTETH).balanceOf(address(newPool)), poolWstBefore - amountOut, "pool wstETH should decrease"
        );
        assertEq(
            IERC20(L2_WETH).balanceOf(address(newPool)), poolWethBefore + stakeAmount, "pool WETH should increase"
        );
    }

    function test_regularStakeAfterMigration() public {
        PausableImmutableOraclePool newPool = _deployAndMigrateL2();
        deal(L2_WETH, address(newPool), 3 ether);
        deal(L2_WSTETH, address(newPool), 7 ether);

        uint256 poolWethBefore = IERC20(L2_WETH).balanceOf(address(newPool));
        uint256 poolWstBefore = IERC20(L2_WSTETH).balanceOf(address(newPool));

        address user = makeAddr("regularStakeUser");
        uint256 stakeAmount = 1 ether;

        bytes memory feeOtoD = FeeCodec.encodeCCIP(0.1e18, false, 1_000_000);
        bytes memory feeDtoO = _defaultFeeDtoO();

        deal(L2_WETH, user, stakeAmount);
        vm.deal(user, 1 ether);

        uint256 userWethBefore = IERC20(L2_WETH).balanceOf(user);

        vm.startPrank(user);
        IERC20(L2_WETH).approve(L2_CUSTOM_SENDER, stakeAmount);
        bytes32 messageId = ICustomSender(L2_CUSTOM_SENDER).slowStake{value: 0.1 ether}(
            ETH_CCIP_CHAIN_SELECTOR, L2_WETH, stakeAmount, feeOtoD, feeDtoO
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0), "regular stake should return a messageId");
        assertEq(
            IERC20(L2_WETH).balanceOf(user),
            userWethBefore - stakeAmount,
            "user WETH should be transferred for regular stake"
        );
        assertEq(
            IERC20(L2_WETH).balanceOf(address(newPool)),
            poolWethBefore,
            "pool WETH should be unchanged for regular stake"
        );
        assertEq(
            IERC20(L2_WSTETH).balanceOf(address(newPool)),
            poolWstBefore,
            "pool wstETH should be unchanged for regular stake"
        );
    }

    function test_migrateL1() public {
        _deployAndMigrateL1();

        assertTrue(
            IAccessControl(L1_LIDO_CUSTOM_RECEIVER).hasRole(DEFAULT_ADMIN_ROLE, LIDO_DAO_AGENT),
            "LIDO_DAO_AGENT should have admin on receiver"
        );
        assertFalse(
            IAccessControl(L1_LIDO_CUSTOM_RECEIVER).hasRole(DEFAULT_ADMIN_ROLE, INITIAL_OWNER),
            "INITIAL_OWNER should lose admin on receiver"
        );

        assertEq(Ownable(L1_PROXY_ADMIN).owner(), LIDO_DAO_AGENT, "L1 ProxyAdmin owner should be LIDO_DAO_AGENT");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, INITIAL_OWNER));
        vm.prank(INITIAL_OWNER);
        Ownable(L1_PROXY_ADMIN).transferOwnership(INITIAL_OWNER);

        _verifyL1PostMigrationState();

        vm.selectFork(l2Fork);
        assertEq(Ownable(L2_PROXY_ADMIN).owner(), INITIAL_OWNER, "L2 ProxyAdmin should start owned by INITIAL_OWNER");
        _migrateL2ProxyAdminOnly();
        assertEq(
            Ownable(L2_PROXY_ADMIN).owner(), LIDO_L2_GOVERNANCE_EXECUTOR, "L2 ProxyAdmin owner should be LIDO_L2_GOVERNANCE_EXECUTOR"
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, INITIAL_OWNER));
        vm.prank(INITIAL_OWNER);
        Ownable(L2_PROXY_ADMIN).transferOwnership(INITIAL_OWNER);
    }

    function test_postMigrationAclRegression() public {
        _deployAndMigrateL2();
        _deployAndMigrateL1();

        vm.selectFork(l2Fork);
        PausableImmutableOraclePool altPool = new PausableImmutableOraclePool(
            L2_CUSTOM_SENDER, L2_WETH, L2_WSTETH, L2_PRICE_ORACLE, 0, LIDO_L2_GOVERNANCE_EXECUTOR
        );

        _expectAccessControlUnauthorized(INITIAL_OWNER, DEFAULT_ADMIN_ROLE);
        vm.prank(INITIAL_OWNER);
        ICustomSender(L2_CUSTOM_SENDER).setOraclePool(address(altPool));

        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        ICustomSender(L2_CUSTOM_SENDER).setOraclePool(address(altPool));
        assertEq(
            ICustomSender(L2_CUSTOM_SENDER).getOraclePool(),
            address(altPool),
            "LIDO_L2_GOVERNANCE_EXECUTOR should be able to set oracle pool"
        );

        vm.selectFork(l1Fork);
        address altAdapter = makeAddr("altAdapter");
        bytes memory altSender = abi.encode(makeAddr("altSender"));

        _expectAccessControlUnauthorized(INITIAL_OWNER, DEFAULT_ADMIN_ROLE);
        vm.prank(INITIAL_OWNER);
        ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).setAdapter(L2_CCIP_CHAIN_SELECTOR, altAdapter);

        _expectAccessControlUnauthorized(INITIAL_OWNER, DEFAULT_ADMIN_ROLE);
        vm.prank(INITIAL_OWNER);
        ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).setSender(L2_CCIP_CHAIN_SELECTOR, altSender);

        vm.prank(LIDO_DAO_AGENT);
        ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).setAdapter(L2_CCIP_CHAIN_SELECTOR, altAdapter);
        vm.prank(LIDO_DAO_AGENT);
        ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).setSender(L2_CCIP_CHAIN_SELECTOR, altSender);

        assertEq(
            ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).getAdapter(L2_CCIP_CHAIN_SELECTOR),
            altAdapter,
            "LIDO_DAO_AGENT should be able to set adapter"
        );
        assertEq(
            ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).getSender(L2_CCIP_CHAIN_SELECTOR),
            altSender,
            "LIDO_DAO_AGENT should be able to set sender"
        );
    }

    function test_oldPoolIsolated() public {
        PausableImmutableOraclePool newPool = _deployAndMigrateL2();
        deal(L2_WSTETH, address(newPool), 100 ether);

        address oldPoolOwner = Ownable(L2_OLD_ORACLE_POOL).owner();
        uint256 oldPoolWst = IERC20(L2_WSTETH).balanceOf(L2_OLD_ORACLE_POOL);

        if (oldPoolWst > 0) {
            vm.prank(oldPoolOwner);
            IOraclePool(L2_OLD_ORACLE_POOL).sweep(L2_WSTETH, oldPoolOwner, oldPoolWst);

            assertEq(IERC20(L2_WSTETH).balanceOf(L2_OLD_ORACLE_POOL), 0, "old pool wstETH should be 0 after sweep");
        }

        address user = makeAddr("user2");
        uint256 stakeAmount = 0.5 ether;
        deal(L2_WETH, user, stakeAmount);

        uint256 newPoolWstBefore = IERC20(L2_WSTETH).balanceOf(address(newPool));
        uint256 oldPoolWethBefore = IERC20(L2_WETH).balanceOf(L2_OLD_ORACLE_POOL);

        vm.startPrank(user);
        IERC20(L2_WETH).approve(L2_CUSTOM_SENDER, stakeAmount);
        ICustomSender(L2_CUSTOM_SENDER).fastStake(L2_WETH, stakeAmount, 0);
        vm.stopPrank();

        assertLt(IERC20(L2_WSTETH).balanceOf(address(newPool)), newPoolWstBefore, "new pool wstETH should decrease");
        assertEq(
            IERC20(L2_WETH).balanceOf(L2_OLD_ORACLE_POOL), oldPoolWethBefore, "old pool WETH should not change"
        );
    }

    function test_liquidityProvision() public {
        PausableImmutableOraclePool newPool = _deployAndMigrateL2();

        uint256 provisionAmount = 50 ether;
        deal(L2_WSTETH, lidoL2LiquidityOwner, provisionAmount);

        uint256 poolWstBeforeProvision = IERC20(L2_WSTETH).balanceOf(address(newPool));

        vm.prank(lidoL2LiquidityOwner);
        assertTrue(IERC20(L2_WSTETH).transfer(address(newPool), provisionAmount), "transfer should succeed");

        uint256 poolWstAfterProvision = IERC20(L2_WSTETH).balanceOf(address(newPool));
        assertEq(
            poolWstAfterProvision,
            poolWstBeforeProvision + provisionAmount,
            "pool wstETH should increase after provision"
        );

        address user = makeAddr("bigUser");
        uint256 stakeAmount = 10 ether;
        deal(L2_WETH, user, stakeAmount);

        uint256 poolWethBeforeFastStake = IERC20(L2_WETH).balanceOf(address(newPool));

        vm.startPrank(user);
        IERC20(L2_WETH).approve(L2_CUSTOM_SENDER, stakeAmount);
        uint256 amountOut = ICustomSender(L2_CUSTOM_SENDER).fastStake(L2_WETH, stakeAmount, 0);
        vm.stopPrank();

        assertGt(amountOut, 0, "large swap should succeed after provision");

        uint256 poolWethAfterFastStake = IERC20(L2_WETH).balanceOf(address(newPool));
        assertEq(poolWethAfterFastStake, poolWethBeforeFastStake + stakeAmount, "pool should hold WETH from swap");

        uint256 poolWstAfterFastStake = IERC20(L2_WSTETH).balanceOf(address(newPool));
        assertEq(
            poolWstAfterFastStake, poolWstAfterProvision - amountOut, "fastStake should consume provided pool wstETH"
        );

        uint256 ownerWethBefore = IERC20(L2_WETH).balanceOf(lidoL2LiquidityOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, LIDO_L2_GOVERNANCE_EXECUTOR));
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        IOraclePool(address(newPool)).sweep(L2_WETH, LIDO_L2_GOVERNANCE_EXECUTOR, poolWethAfterFastStake);

        vm.prank(lidoL2LiquidityOwner);
        IOraclePool(address(newPool)).sweep(L2_WETH, lidoL2LiquidityOwner, poolWethAfterFastStake);

        assertEq(
            IERC20(L2_WETH).balanceOf(lidoL2LiquidityOwner),
            ownerWethBefore + poolWethAfterFastStake,
            "owner should receive swept WETH"
        );
        assertEq(IERC20(L2_WETH).balanceOf(address(newPool)), 0, "pool WETH should be 0 after sweep");

        uint256 remainingWstLiquidity = IERC20(L2_WSTETH).balanceOf(address(newPool));
        assertGt(remainingWstLiquidity, 0, "pool should still have remaining wstETH liquidity");

        uint256 ownerWstBefore = IERC20(L2_WSTETH).balanceOf(lidoL2LiquidityOwner);
        vm.prank(lidoL2LiquidityOwner);
        IOraclePool(address(newPool)).sweep(L2_WSTETH, lidoL2LiquidityOwner, remainingWstLiquidity);

        assertEq(
            IERC20(L2_WSTETH).balanceOf(lidoL2LiquidityOwner),
            ownerWstBefore + remainingWstLiquidity,
            "liquidity provider should receive remaining wstETH liquidity"
        );
        assertEq(IERC20(L2_WSTETH).balanceOf(address(newPool)), 0, "pool wstETH should be 0 after full sweep");
    }

    function test_poolPauseUnpause() public {
        PausableImmutableOraclePool newPool = _deployAndMigrateL2();
        deal(L2_WSTETH, address(newPool), 100 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, LIDO_L2_GOVERNANCE_EXECUTOR));
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        newPool.pause();

        vm.prank(lidoL2LiquidityOwner);
        newPool.pause();
        assertTrue(newPool.paused(), "pool should be paused");

        address user = makeAddr("pausedUser");
        deal(L2_WETH, user, 1 ether);
        vm.startPrank(user);
        IERC20(L2_WETH).approve(L2_CUSTOM_SENDER, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("EnforcedPause()"))));
        ICustomSender(L2_CUSTOM_SENDER).fastStake(L2_WETH, 1 ether, 0);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, LIDO_L2_GOVERNANCE_EXECUTOR));
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        newPool.unpause();

        vm.prank(lidoL2LiquidityOwner);
        newPool.unpause();
        assertFalse(newPool.paused(), "pool should be unpaused");

        vm.startPrank(user);
        uint256 amountOut = ICustomSender(L2_CUSTOM_SENDER).fastStake(L2_WETH, 1 ether, 0);
        vm.stopPrank();
        assertGt(amountOut, 0, "fastStake should succeed after unpause");
    }

    function test_rebalanceViaSync() public {
        PausableImmutableOraclePool newPool = _deployAndMigrateL2();
        uint256 stakeAmount = 5 ether;
        uint256 poolWeth = _provisionPoolAndAccumulateWeth(newPool, stakeAmount);
        assertEq(poolWeth, stakeAmount, "pool should have accumulated WETH from swaps");

        address rebalancer = makeAddr("rebalancer");

        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        IAccessControl(L2_CUSTOM_SENDER).grantRole(SYNC_ROLE, rebalancer);

        assertTrue(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, rebalancer), "rebalancer should have SYNC_ROLE"
        );

        (bytes memory feeOtoD, bytes memory feeDtoO) = _defaultSyncFees();

        uint256 syncAmount = poolWeth;
        vm.deal(rebalancer, 1 ether);

        vm.prank(rebalancer);
        bytes32 messageId = ICustomSender(L2_CUSTOM_SENDER).sync{value: 0.1 ether}(
            ETH_CCIP_CHAIN_SELECTOR, syncAmount, feeOtoD, feeDtoO
        );

        assertTrue(messageId != bytes32(0), "sync should return a messageId");
        assertEq(IERC20(L2_WETH).balanceOf(address(newPool)), 0, "pool WETH should be 0 after sync");

        address unauthorized = makeAddr("unauthorized");
        vm.deal(unauthorized, 1 ether);

        _expectAccessControlUnauthorized(unauthorized, SYNC_ROLE);
        vm.prank(unauthorized);
        ICustomSender(L2_CUSTOM_SENDER).sync{value: 0.1 ether}(ETH_CCIP_CHAIN_SELECTOR, 1 ether, feeOtoD, feeDtoO);
    }

    function test_deployedSyncTriggerIsOperational() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        assertEq(
            _provisionPoolAndAccumulateWeth(newPool, stakeAmount),
            stakeAmount,
            "pool should have accumulated WETH for sync"
        );

        address forwarder = makeAddr("chainlinkForwarder");
        vm.prank(lidoL2LiquidityOwner);
        syncTrigger.setForwarder(forwarder);
        assertEq(syncTrigger.getForwarder(), forwarder, "forwarder should be configured");

        assertEq(syncTrigger.shouldSyncAmount(), 0, "sync should not be needed before delay");

        vm.warp(block.timestamp + L2_SYNC_DELAY);

        uint256 expectedSyncAmount = stakeAmount > uint256(L2_SYNC_MAX_AMOUNT) ? L2_SYNC_MAX_AMOUNT : stakeAmount;
        {
            assertEq(
                syncTrigger.shouldSyncAmount(),
                expectedSyncAmount,
                "sync should be needed after delay; amount should equal expected sync amount"
            );
        }

        uint256 maxNativeFee = syncTrigger.getMaxFees();
        vm.deal(address(syncTrigger), maxNativeFee);

        address unauthorizedForwarder = makeAddr("notForwarder");
        vm.prank(unauthorizedForwarder);
        vm.expectRevert(SyncTrigger.SyncTriggerOnlyForwarder.selector);
        syncTrigger.triggerSync();

        uint48 lastExecutionBefore = syncTrigger.getLastExecution();
        vm.prank(forwarder);
        syncTrigger.triggerSync();

        assertEq(
            IERC20(L2_WETH).balanceOf(address(newPool)),
            stakeAmount - expectedSyncAmount,
            "pool WETH should decrease by synced amount"
        );
        assertEq(syncTrigger.getLastExecution(), uint48(block.timestamp), "last execution should update");
        assertGt(syncTrigger.getLastExecution(), lastExecutionBefore, "last execution should move forward");

        {
            assertEq(syncTrigger.shouldSyncAmount(), 0, "sync should be false immediately after trigger");
        }
    }

    function test_consecutiveSyncCycles() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        address forwarder = makeAddr("cycleForwarder");
        vm.prank(lidoL2LiquidityOwner);
        syncTrigger.setForwarder(forwarder);

        // Use a short delay to avoid CCIP StaleTokenPrice on double-warp;
        // delay enforcement is already tested by other tests.
        uint48 shortDelay = 60;
        vm.prank(lidoL2LiquidityOwner);
        syncTrigger.setDelay(shortDelay);

        uint256 maxNativeFee = syncTrigger.getMaxFees();

        // ── Cycle 1: accumulate WETH, wait delay, sync ──
        _provisionPoolAndAccumulateWeth(newPool, uint256(L2_SYNC_MIN_AMOUNT) + 1 ether);
        vm.warp(block.timestamp + shortDelay);

        // Fund the float so the upcoming triggerSync can pay (shouldSyncAmount itself ignores the float).
        vm.deal(address(syncTrigger), maxNativeFee);

        {
            assertGt(syncTrigger.shouldSyncAmount(), 0, "cycle 1: sync should be due (amount > 0)");
        }

        vm.prank(forwarder);
        syncTrigger.triggerSync();

        uint48 exec1 = syncTrigger.getLastExecution();
        assertEq(exec1, uint48(block.timestamp), "cycle 1: lastExecution should update");

        {
            assertEq(syncTrigger.shouldSyncAmount(), 0, "cycle 1: sync should be false right after trigger");
        }

        // ── Cycle 2: accumulate more WETH, wait delay, sync again ──
        deal(L2_WSTETH, address(newPool), 100 ether);
        {
            address user2 = makeAddr("cycleUser2");
            uint256 stake2 = uint256(L2_SYNC_MIN_AMOUNT) + 2 ether;
            deal(L2_WETH, user2, stake2);
            vm.startPrank(user2);
            IERC20(L2_WETH).approve(L2_CUSTOM_SENDER, stake2);
            ICustomSender(L2_CUSTOM_SENDER).fastStake(L2_WETH, stake2, 0);
            vm.stopPrank();
        }

        {
            assertEq(syncTrigger.shouldSyncAmount(), 0, "cycle 2: sync should be false before delay");
        }

        vm.warp(block.timestamp + shortDelay);
        vm.deal(address(syncTrigger), maxNativeFee); // re-fund the float (cycle 1's sync consumed it)

        {
            assertGt(syncTrigger.shouldSyncAmount(), 0, "cycle 2: sync should be due (amount > 0)");
        }

        uint256 poolWethBefore = IERC20(L2_WETH).balanceOf(address(newPool));
        vm.prank(forwarder);
        syncTrigger.triggerSync();

        assertGt(syncTrigger.getLastExecution(), exec1, "cycle 2: lastExecution should advance past cycle 1");
        assertLt(IERC20(L2_WETH).balanceOf(address(newPool)), poolWethBefore, "cycle 2: pool WETH should decrease");
    }

    function test_syncTriggerRevertsWithInsufficientFees() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);

        address forwarder = makeAddr("feeTestForwarder");
        vm.prank(lidoL2LiquidityOwner);
        syncTrigger.setForwarder(forwarder);

        vm.warp(block.timestamp + L2_SYNC_DELAY);

        assertGt(syncTrigger.shouldSyncAmount(), 0, "sync should be needed");

        // The migration hands the trigger over drained (handoff sweeps the float), but drain defensively
        // anyway so this test always exercises the float-ran-dry path: with a 0 balance, triggerSync must
        // revert when it tries to forward the native CCIP fee from its own balance.
        uint256 floatBalance = address(syncTrigger).balance;
        if (floatBalance > 0) {
            vm.prank(lidoL2LiquidityOwner);
            syncTrigger.sweep(address(0), makeAddr("floatSink"), floatBalance);
        }
        assertEq(address(syncTrigger).balance, 0, "sync trigger should have no ETH");

        vm.prank(forwarder);
        vm.expectRevert();
        syncTrigger.triggerSync();
    }

    /// @dev The canary governance seal must refuse a mis-wired Stage 1 BEFORE any irreversible write
    ///      (old-automation revoke, admin revoke, ProxyAdmin handover). Here the canary is deployed +
    ///      activated correctly, but finalize is handed a creReceiver the trigger's forwarder does not
    ///      point at — the opening {_assertSyncInfrastructure} interlock fails and nothing is sealed.
    function test_canaryFinalizeRevertsOnMiswiredStage1() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger,,) = _bindCanaryL2();

        L2UpgradeConfig memory cfg =
            _defaultL2Config(INITIAL_OWNER, LIDO_L2_GOVERNANCE_EXECUTOR, lidoL2LiquidityOwner);
        address realForwarder = creForwarder;

        // Call via `this.` so finalizeGovernanceSeal runs as a single external call and the interlock
        // revert is caught atomically (expectRevert latches onto the next external call). The trigger's
        // forwarder points at the real (deployer-wired) CREReceiver, so the mismatched wrongReceiver trips
        // "syncTrigger forwarder" before the irreversible seal in {_sealAdminAndProxy}.
        address wrongReceiver = makeAddr("wrongReceiver");
        vm.expectRevert(abi.encodeWithSelector(L2UpgradePostConditionFailed.selector, "syncTrigger forwarder"));
        this.finalizeGovernanceSeal(cfg, address(newPool), address(syncTrigger), wrongReceiver, realForwarder);
    }

    function test_syncTriggerNotTriggeredWhenBalanceBelowMinAfterDelay() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 amountBelowMin = uint256(L2_SYNC_MIN_AMOUNT) - 1;
        assertEq(
            _provisionPoolAndAccumulateWeth(newPool, amountBelowMin),
            amountBelowMin,
            "pool should have WETH below min threshold"
        );

        bool syncNeeded = _shouldSyncAfterDelay(syncTrigger);
        assertFalse(syncNeeded, "sync should stay false when balance is below min");
    }

    function test_syncTriggerTriggersAtExactMinAmount() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 exactMinAmount = uint256(L2_SYNC_MIN_AMOUNT);
        assertEq(
            _provisionPoolAndAccumulateWeth(newPool, exactMinAmount), exactMinAmount, "pool should have exact min WETH"
        );

        bool syncNeeded = _shouldSyncAfterDelay(syncTrigger);
        assertTrue(syncNeeded, "sync should trigger at exact min amount");
        assertEq(syncTrigger.shouldSyncAmount(), exactMinAmount, "amount should be the exact min amount");
    }

    function test_syncTriggerCapsAtMaxAmount() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 balanceAboveMax = uint256(L2_SYNC_MAX_AMOUNT) + 1 ether;
        deal(L2_WETH, address(newPool), balanceAboveMax);

        bool syncNeeded = _shouldSyncAfterDelay(syncTrigger);
        assertTrue(syncNeeded, "sync should trigger when balance is above max");
        assertEq(syncTrigger.shouldSyncAmount(), uint256(L2_SYNC_MAX_AMOUNT), "amount should cap at max");
    }

    function test_upgradeSyncRoutesAcrossL2AndL1CCIPLayer() public {
        PausableImmutableOraclePool newPool = _deployAndMigrateL2();
        _deployAndMigrateL1();

        vm.selectFork(l1Fork);

        MockBridgeAdapter mockAdapter = new MockBridgeAdapter();

        vm.prank(LIDO_DAO_AGENT);
        ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).setAdapter(L2_CCIP_CHAIN_SELECTOR, address(mockAdapter));

        assertEq(
            ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).getSender(L2_CCIP_CHAIN_SELECTOR),
            abi.encode(L2_CUSTOM_SENDER),
            "L1 receiver sender should remain L2 CustomSender"
        );
        assertEq(
            ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).getAdapter(L2_CCIP_CHAIN_SELECTOR),
            address(mockAdapter),
            "L1 receiver adapter should be replaced with test mock"
        );

        (bytes32 messageId, bytes32 feeDtoOHash) = _prepareAndSyncL2(newPool);

        vm.selectFork(l1Fork);
        uint256 receiverWstBefore = IERC20(L1_WSTETH).balanceOf(L1_LIDO_CUSTOM_RECEIVER);

        _routeCCIPMessage(
            l2Fork,
            l1Fork,
            L2_CCIP_ROUTER,
            ETH_CCIP_CHAIN_SELECTOR,
            L1_LIDO_CUSTOM_RECEIVER,
            L1_CCIP_ROUTER
        );
        assertEq(vm.activeFork(), l1Fork, "routing should switch to L1 fork");

        // ── FeeOtoD.gasLimit adequacy carrier (A.10 validatedBy) ───────────────────────────────────
        // Record the measured L1 `ccipReceive` gas — the work `FeeOtoD.gasLimit` budgets — as a
        // regenerating, per-lane in-repo artifact. This replaces the old-value-relative justification
        // in README §"Glamsterdam fee headroom bump" ("+25% over the prior baseline") with an
        // independent carrier. Caveat (stated, not hidden): this route uses MockBridgeAdapter, so the
        // figure is a LOWER BOUND — it omits the real per-network L1 bridge endpoint
        // (L1StandardBridge / L1GatewayRouter / L1MessageService), which is also inside the budgeted
        // path. Promote the projection check below to a hard assert once measured with the real adapter.
        if (lastCcipReceiveGasUsed != 0) {
            uint256 measuredGas = lastCcipReceiveGasUsed;
            uint256 gasLimit = L2_SYNC_DESTINATION_GAS_LIMIT;
            // Independent adequacy read (no prior value): Monitoring §5 wants ccipReceive/gasLimit < 80%,
            // and Glamsterdam (EIP-7904/8038) reprices this cold-access-heavy path by ~+25%. So the
            // post-Glamsterdam projection (x1.25) should still fit the budget.
            console2.log("[FeeOtoD.gasLimit carrier] L2 CCIP selector:", L2_CCIP_CHAIN_SELECTOR);
            console2.log("  measured ccipReceive gas (LOWER BOUND - mock adapter):", measuredGas);
            console2.log("  configured FeeOtoD.gasLimit:", gasLimit);
            console2.log("  utilization (bps of gasLimit):", measuredGas * 10_000 / gasLimit);
            console2.log("  Glamsterdam-projected gas (x1.25):", measuredGas * 125 / 100);
            // Safe regression floor: even the lower-bound receive must fit the configured budget.
            assertLt(measuredGas, gasLimit, "ccipReceive lower-bound gas must fit FeeOtoD.gasLimit");
        } else {
            console2.log("[FeeOtoD.gasLimit carrier] ccipReceive gas not isolated (v1.5 route) - selector:", L2_CCIP_CHAIN_SELECTOR);
        }

        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 bridgedWstAmount = _assertAndGetAdapterDispatch(entries, address(newPool), feeDtoOHash);

        assertEq(
            ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).getFailedMessageHash(messageId),
            bytes32(0),
            "L1 receiver should process CCIP message"
        );
        assertEq(
            IERC20(L1_WSTETH).balanceOf(L1_LIDO_CUSTOM_RECEIVER) - receiverWstBefore,
            bridgedWstAmount,
            "L1 receiver wstETH delta should equal bridged amount"
        );

        _simulateL2BridgeFinalization(address(newPool), bridgedWstAmount);
    }

    /// @notice Faithful `FeeOtoD.gasLimit` adequacy carrier: measures L1 `ccipReceive` gas with the
    ///         REAL per-network bridge adapter (no mock), so the figure includes the real bridge
    ///         endpoint (`L1StandardBridge` / `L1GatewayRouter` / `L1MessageService`) that the mock
    ///         routing test omits. Recorded as a regenerating artifact (A.10 `validatedBy`); the
    ///         §5/Glamsterdam projection is hard-asserted here because the number is complete.
    function test_ccipReceiveGasRealAdapter() public {
        PausableImmutableOraclePool newPool = _deployAndMigrateL2();
        _deployAndMigrateL1(); // leaves the REAL per-network L1 adapter configured (not the mock)

        (bytes32 messageId,) = _prepareAndSyncL2(newPool);

        vm.selectFork(l1Fork);
        // In production the L1 receiver forwards FeeDtoO native value to the bridge (Arbitrum retryable
        // submission cost); the fork message-injection doesn't carry that ETH, so pre-fund the receiver.
        vm.deal(L1_LIDO_CUSTOM_RECEIVER, 1 ether);

        _routeCCIPMessage(
            l2Fork,
            l1Fork,
            L2_CCIP_ROUTER,
            ETH_CCIP_CHAIN_SELECTOR,
            L1_LIDO_CUSTOM_RECEIVER,
            L1_CCIP_ROUTER
        );

        assertEq(
            ICustomReceiver(L1_LIDO_CUSTOM_RECEIVER).getFailedMessageHash(messageId),
            bytes32(0),
            "real-adapter ccipReceive must not enter the failed state"
        );

        uint256 measuredGas = lastCcipReceiveGasUsed;
        if (measuredGas != 0) {
            uint256 gasLimit = L2_SYNC_DESTINATION_GAS_LIMIT;
            // Independent adequacy read (no prior value): Monitoring §5 wants ccipReceive/gasLimit < 80%,
            // and Glamsterdam (EIP-7904/8038) reprices this cold-access-heavy path by ~+25%. So the
            // post-Glamsterdam projection (x1.25) must still fit the configured budget.
            console2.log("[FeeOtoD.gasLimit carrier - REAL adapter] L2 CCIP selector:", L2_CCIP_CHAIN_SELECTOR);
            console2.log("  measured ccipReceive gas:", measuredGas);
            console2.log("  configured FeeOtoD.gasLimit:", gasLimit);
            console2.log("  utilization (bps of gasLimit):", measuredGas * 10_000 / gasLimit);
            console2.log("  Glamsterdam-projected gas (x1.25):", measuredGas * 125 / 100);
            assertLe(
                measuredGas * 125,
                gasLimit * 100,
                "post-Glamsterdam ccipReceive (x1.25) would exceed FeeOtoD.gasLimit (OOG) - re-derive the gasLimit"
            );
        } else {
            console2.log("[FeeOtoD.gasLimit carrier - REAL adapter] ccipReceive gas not isolated (v1.5 route) - selector:", L2_CCIP_CHAIN_SELECTOR);
        }
    }

    function test_productionMigrationPath() public {
        (, address newSyncTrigger, CREReceiver newCREReceiver) =
            _deployAndMigrateL2Production();

        _verifySyncTriggerConfig(newSyncTrigger, address(newCREReceiver));
        _verifyOldAutomationsRevoked();

        assertEq(
            Ownable(address(newCREReceiver)).owner(),
            lidoL2LiquidityOwner,
            "CREReceiver owner should be liquidity owner (LOL)"
        );
        // The CRE workflow owner is the LOL multisig (Safe), pinned as expectedAuthor — NOT the
        // Lido Deployer EOA that broadcasts Stage 1 (ADR-0001 / DOC.md §3.2). Owner, expectedAuthor,
        // and workflow owner are the same Safe address. (This is the static-state check; the
        // CRE-suite test_productionExpectedAuthorIsLolMultisig additionally proves the behavioral
        // accept/reject of the author gate — keep both.)
        assertEq(
            newCREReceiver.getExpectedAuthor(),
            lidoL2LiquidityOwner,
            "CREReceiver expectedAuthor should be the LOL multisig, not the deployer EOA"
        );
        assertTrue(
            newCREReceiver.getExpectedAuthor() != lidoStage1Deployer,
            "expectedAuthor must not be the Stage-1 deployer EOA"
        );
        assertEq(
            newCREReceiver.getForwarder(),
            creForwarder,
            "CREReceiver forwarder should be set"
        );

        // Old automation is blocked from calling sync
        if (L2_OLD_CHAINLINK_AUTOMATION != address(0)) {
            (bytes memory feeOtoD, bytes memory feeDtoO) = _defaultSyncFees();
            vm.deal(L2_OLD_CHAINLINK_AUTOMATION, 1 ether);
            _expectAccessControlUnauthorized(L2_OLD_CHAINLINK_AUTOMATION, SYNC_ROLE);
            vm.prank(L2_OLD_CHAINLINK_AUTOMATION);
            ICustomSender(L2_CUSTOM_SENDER).sync{value: 0.1 ether}(
                ETH_CCIP_CHAIN_SELECTOR, 1 ether, feeOtoD, feeDtoO
            );
        }
    }

    /// @dev Production-parity float provenance test: the migration hands the trigger over DRAINED
    ///      (handoff sweeps the whole test float back to the deployer), and the first production sync
    ///      must succeed funded ONLY by the explicit post-migration funding step (`just fund-trigger` →
    ///      {fundSyncTrigger}, permissionless on the LOL-owned trigger). Deliberately no
    ///      `vm.deal(address(syncTrigger), …)` here — that out-of-band funding in the other sync tests
    ///      is exactly what masked an unfunded production trigger (the negative case,
    ///      `test_syncTriggerRevertsWithInsufficientFees`, proves the revert; this proves the
    ///      production recipe prevents it).
    function test_fundTriggerStepFundsSyncTriggerFloatForFirstSync() public {
        (PausableImmutableOraclePool newPool, address newSyncTrigger, CREReceiver newCREReceiver) =
            _deployAndMigrateL2Production();
        SyncTrigger syncTrigger = SyncTrigger(payable(newSyncTrigger));

        // The migration end state: the handoff swept the trigger's whole ETH float back to the deployer.
        assertEq(newSyncTrigger.balance, 0, "migration should hand the trigger over drained");

        // The explicit funding step (permissionless; production runs it as `just fund-trigger`) seeds
        // exactly the configured constant.
        L2UpgradeConfig memory cfg =
            _defaultL2Config(INITIAL_OWNER, LIDO_L2_GOVERNANCE_EXECUTOR, lidoL2LiquidityOwner);
        uint256 initialFloat = cfg.syncTriggerInitialFloat;
        vm.deal(address(this), initialFloat);
        fundSyncTrigger(newSyncTrigger, cfg);
        assertEq(newSyncTrigger.balance, initialFloat, "fund-trigger should fund exactly the configured float");

        // Floor invariant: the float covers at least one worst-case sync (mirrors fundSyncTrigger's guard).
        uint256 maxNativeFee = syncTrigger.getMaxFees();
        assertGe(initialFloat, maxNativeFee, "float must cover one worst-case sync");

        // Fee non-drift: the deploy-script copy of the native fee total (the inherited {_maxFees}, the path
        // `verify-constants-sync` exercises) must agree with the live on-chain `SyncTrigger.getMaxFees()`
        // for the real per-lane production blobs. This is the tested cross-check that replaces the deleted
        // shared {FeeSplit} library's structural single-source guarantee (the two copies are also pinned to
        // the same `<net>.inputs.yaml` anchors by verify-constants-sync + state-mate).
        uint256 scriptNativeFee = _maxFees(_encodeFeeOtoD(cfg), cfg.feeDtoO);
        assertEq(scriptNativeFee, maxNativeFee, "fee drift: deploy script vs SyncTrigger");

        _provisionPoolAndAccumulateWeth(newPool, uint256(L2_SYNC_MIN_AMOUNT) + 1 ether);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        assertGt(syncTrigger.shouldSyncAmount(), 0, "sync should be needed");

        // First sync, paid solely from the fund-trigger float (forwarder = CREReceiver in production wiring).
        vm.prank(address(newCREReceiver));
        syncTrigger.triggerSync();

        // Refund mechanics: the float drains by the actual fee only; the maxFee excess refunds to the trigger.
        assertLt(newSyncTrigger.balance, initialFloat, "sync should spend from the float");
        assertGt(newSyncTrigger.balance, initialFloat - maxNativeFee, "maxFee excess should refund to the trigger");
    }

    // ──────────────── Canary flow (deployer-simulated CRE) ───────────────

    /// @notice Full canary path: deploy deployer-owned + deployer-as-CRE → activate → simulate a sync via
    ///         CREReceiver.onReport → handoff to LOL (restore real forwarder/author + production params) →
    ///         seal governance. The end-state must match what the standard migration lands on.
    function test_canaryDeployerSimulatedSyncAndHandoff() public {
        // Stage-1 invariants are already hard-asserted inside the bind (with the live delay/min-amount).
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger, CREReceiver creReceiver, address deployer) =
            _bindCanaryL2();

        // Seed WETH above the canary min, wait the live canary delay, then drive a sync via onReport.
        uint256 seed = 0.1 ether;
        deal(L2_WETH, address(newPool), seed);
        vm.warp(block.timestamp + syncTrigger.getDelay() + 1);
        assertEq(syncTrigger.shouldSyncAmount(), seed, "canary: sync due for the seeded WETH");

        // Deployer is the configured forwarder AND author; craft the Keystone report and call onReport.
        bytes memory metadata = abi.encodePacked(bytes32(0), bytes10(0), deployer);
        bytes memory report = abi.encode(address(syncTrigger), abi.encodePacked(SyncTrigger.triggerSync.selector));
        vm.prank(deployer);
        creReceiver.onReport(metadata, report);
        assertEq(IERC20(L2_WETH).balanceOf(address(newPool)), 0, "canary sync should pull the pool WETH");

        // Stage 1→2 (Deployer): sweep residue (pool WETH/wstETH + the trigger's whole ETH float back to
        // the deployer), restore production config, transfer to LOL.
        address realForwarder = creForwarder;
        L2UpgradeConfig memory prodCfg =
            _defaultL2Config(INITIAL_OWNER, LIDO_L2_GOVERNANCE_EXECUTOR, lidoL2LiquidityOwner);
        uint256 deployerEthBefore = deployer.balance;
        uint256 triggerFloatBefore = address(syncTrigger).balance;
        vm.startPrank(deployer);
        sweepTestResidue(prodCfg, address(newPool), address(syncTrigger), deployer);
        handoffToLiquidityOwner(prodCfg, address(newPool), address(syncTrigger), address(creReceiver), realForwarder);
        vm.stopPrank();

        // The handoff recovers ALL the deployer-provided funds: the trigger is handed over empty.
        assertEq(address(syncTrigger).balance, 0, "handoff should drain the trigger's whole ETH float");
        assertEq(deployer.balance, deployerEthBefore + triggerFloatBefore, "trigger float swept to the deployer");
        assertEq(IERC20(L2_WETH).balanceOf(address(newPool)), 0, "pool WETH swept");
        assertEq(IERC20(L2_WSTETH).balanceOf(address(newPool)), 0, "pool wstETH swept");

        verifyCanaryStage2(prodCfg, address(newPool), address(syncTrigger), address(creReceiver), realForwarder);

        // Stage 2→3 (Initial Owner): the irreversible governance seal.
        vm.startPrank(INITIAL_OWNER);
        finalizeGovernanceSeal(prodCfg, address(newPool), address(syncTrigger), address(creReceiver), realForwarder);
        vm.stopPrank();

        // Final production state — the same invariants the standard migration lands on.
        assertEq(newPool.owner(), lidoL2LiquidityOwner, "pool owner = LOL");
        assertEq(Ownable(address(syncTrigger)).owner(), lidoL2LiquidityOwner, "trigger owner = LOL");
        assertEq(Ownable(address(creReceiver)).owner(), lidoL2LiquidityOwner, "receiver owner = LOL");
        assertEq(creReceiver.getExpectedAuthor(), lidoL2LiquidityOwner, "author restored to LOL");
        assertEq(creReceiver.getForwarder(), realForwarder, "forwarder restored to real");
        (uint128 minA, uint128 maxA) = syncTrigger.getAmounts();
        assertEq(minA, L2_SYNC_MIN_AMOUNT, "min restored to production");
        assertEq(maxA, L2_SYNC_MAX_AMOUNT, "max = production");
        assertEq(syncTrigger.getDelay(), L2_SYNC_DELAY, "delay restored to production");
        assertTrue(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(DEFAULT_ADMIN_ROLE, LIDO_L2_GOVERNANCE_EXECUTOR),
            "admin = governance executor"
        );
        assertFalse(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(DEFAULT_ADMIN_ROLE, INITIAL_OWNER), "initial owner admin revoked"
        );
        assertEq(Ownable(L2_PROXY_ADMIN).owner(), LIDO_L2_GOVERNANCE_EXECUTOR, "L2 ProxyAdmin = governance executor");
        _verifyOldAutomationsRevoked();
    }

    /// @notice Behavioral canary acceptance against the REAL on-chain deployed addresses (bind-only —
    ///         the env addresses are required): bind to the deployer-owned canary, seed WETH above the
    ///         on-chain min, wait the on-chain delay, drive a sync via CREReceiver.onReport as the
    ///         deployer, and assert the pool WETH is pulled. The non-destructive, keyless fork sibling of
    ///         the on-chain `simulate-sync` real-broadcast path. Driven by `just test-<net>-canary-acceptance`.
    function test_canarySyncOnDeployedAddresses() public {
        (PausableImmutableOraclePool pool, SyncTrigger trigger, CREReceiver receiver, address deployer) =
            _bindCanaryL2();

        // Seed above the on-chain canary min (deal SETS the balance, so the drain-to-0 assert is
        // deterministic even against a live pool that already holds WETH); the seed is far below any lane
        // maxAmount, so the full seed syncs in one shot.
        (uint128 minA,) = trigger.getAmounts();
        uint256 seed = uint256(minA) + 0.05 ether;
        deal(L2_WETH, address(pool), seed);

        // Warp past the on-chain delay (relative to now, +1) so a possibly-recent on-chain lastExecution
        // cannot leave the sync un-due.
        vm.warp(block.timestamp + trigger.getDelay() + 1);
        assertGt(trigger.shouldSyncAmount(), 0, "canary: sync should be due for the seeded WETH");

        // Deployer is the configured forwarder AND author; craft the Keystone report and call onReport
        // (byte-identical to runSimulateSync / test_canaryDeployerSimulatedSyncAndHandoff).
        bytes memory metadata = abi.encodePacked(bytes32(0), bytes10(0), deployer);
        bytes memory report = abi.encode(address(trigger), abi.encodePacked(SyncTrigger.triggerSync.selector));
        vm.prank(deployer);
        receiver.onReport(metadata, report);

        assertEq(IERC20(L2_WETH).balanceOf(address(pool)), 0, "canary sync should pull the seeded pool WETH");
    }

    /// @notice 1→0 rollback: after activation, the Initial Owner repoints CustomSender at the old pool and
    ///         revokes the new SyncTrigger's SYNC_ROLE. The old automation was never touched, so the
    ///         predecessor system is fully restored.
    function test_canaryRollbackRestoresOldPool() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger,,) = _bindCanaryL2();

        assertEq(ICustomSender(L2_CUSTOM_SENDER).getOraclePool(), address(newPool), "pool activated");
        assertTrue(IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, address(syncTrigger)), "trigger has SYNC_ROLE");

        // The legacy automations' LIVE role state (which of the pinned addresses actually still holds
        // SYNC_ROLE varies by lane — e.g. Linea's holder is the Gelato bot, not the Chainlink upkeep):
        // rollback must PRESERVE it, whatever it is, so capture before and compare after.
        bool chainlinkHadRole = L2_OLD_CHAINLINK_AUTOMATION != address(0)
            && IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, L2_OLD_CHAINLINK_AUTOMATION);
        bool gelatoHadRole = L2_OLD_GELATO_AUTOMATION != address(0)
            && IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, L2_OLD_GELATO_AUTOMATION);
        assertTrue(
            chainlinkHadRole || gelatoHadRole, "some legacy automation still holds SYNC_ROLE pre-rollback"
        );

        vm.startPrank(INITIAL_OWNER);
        rollbackActivation(_canaryCfg(), L2_OLD_ORACLE_POOL, address(syncTrigger));
        vm.stopPrank();

        assertEq(ICustomSender(L2_CUSTOM_SENDER).getOraclePool(), L2_OLD_ORACLE_POOL, "rolled back to old pool");
        assertFalse(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, address(syncTrigger)), "trigger SYNC_ROLE revoked"
        );
        if (L2_OLD_CHAINLINK_AUTOMATION != address(0)) {
            assertEq(
                IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, L2_OLD_CHAINLINK_AUTOMATION),
                chainlinkHadRole,
                "chainlink automation SYNC_ROLE preserved for clean rollback"
            );
        }
        if (L2_OLD_GELATO_AUTOMATION != address(0)) {
            assertEq(
                IAccessControl(L2_CUSTOM_SENDER).hasRole(SYNC_ROLE, L2_OLD_GELATO_AUTOMATION),
                gelatoHadRole,
                "gelato automation SYNC_ROLE preserved for clean rollback"
            );
        }
        assertTrue(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(DEFAULT_ADMIN_ROLE, INITIAL_OWNER), "admin still initial owner"
        );
    }

    /// @notice Sealing before the LOL handoff must revert: the infra is still deployer-owned, so the
    ///         {finalizeGovernanceSeal} interlock fails (owner != LOL) before any irreversible write.
    function test_canaryFinalizeRevertsBeforeHandoff() public {
        (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger, CREReceiver creReceiver,) = _bindCanaryL2();
        L2UpgradeConfig memory prodCfg =
            _defaultL2Config(INITIAL_OWNER, LIDO_L2_GOVERNANCE_EXECUTOR, lidoL2LiquidityOwner);
        address realForwarder = creForwarder;

        // `this.` so the external call is what expectRevert latches onto; the interlock reverts first.
        vm.expectRevert(abi.encodeWithSelector(L2UpgradePostConditionFailed.selector, "syncTrigger owner"));
        this.finalizeGovernanceSeal(prodCfg, address(newPool), address(syncTrigger), address(creReceiver), realForwarder);

        assertTrue(
            IAccessControl(L2_CUSTOM_SENDER).hasRole(DEFAULT_ADMIN_ROLE, INITIAL_OWNER), "admin untouched after revert"
        );
    }

    // ──────────────── Internal test helpers ──────────────────────────────

    function _deployAndLoadSyncTrigger()
        internal
        returns (PausableImmutableOraclePool newPool, SyncTrigger syncTrigger)
    {
        address syncTriggerAddress;
        (newPool, syncTriggerAddress) = _deployAndMigrateL2WithSyncTrigger();
        syncTrigger = SyncTrigger(payable(syncTriggerAddress));
    }

    function _shouldSyncAfterDelay(SyncTrigger syncTrigger)
        internal
        returns (bool syncNeeded)
    {
        vm.warp(block.timestamp + L2_SYNC_DELAY);
        syncNeeded = syncTrigger.shouldSyncAmount() > 0;
    }
}
