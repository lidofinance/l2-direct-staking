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
import {ISyncTrigger} from "src/interfaces/ISyncTrigger.sol";
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
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        assertEq(
            _provisionPoolAndAccumulateWeth(newPool, stakeAmount),
            stakeAmount,
            "pool should have accumulated WETH for sync"
        );

        address forwarder = makeAddr("chainlinkForwarder");
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        syncTrigger.setForwarder(forwarder);
        assertEq(syncTrigger.getForwarder(), forwarder, "forwarder should be configured");

        (bool syncBeforeDelay,) = syncTrigger.shouldSync();
        assertFalse(syncBeforeDelay, "sync should not be needed before delay");

        vm.warp(block.timestamp + L2_SYNC_DELAY);

        uint256 expectedSyncAmount = stakeAmount > uint256(L2_SYNC_MAX_AMOUNT) ? L2_SYNC_MAX_AMOUNT : stakeAmount;
        {
            (bool syncNeeded, uint256 amount) = syncTrigger.shouldSync();
            assertTrue(syncNeeded, "sync should be needed after delay and min amount");
            assertEq(amount, expectedSyncAmount, "amount should equal expected sync amount");
        }

        (uint256 maxNativeFee, uint256 maxLinkFee) = syncTrigger.getMaxFees();
        assertEq(maxLinkFee, 0, "sync should not require LINK fee");
        vm.deal(address(syncTrigger), maxNativeFee);

        address unauthorizedForwarder = makeAddr("notForwarder");
        vm.prank(unauthorizedForwarder);
        vm.expectRevert(ISyncTrigger.SyncTriggerOnlyForwarder.selector);
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
            (bool syncAfterTrigger,) = syncTrigger.shouldSync();
            assertFalse(syncAfterTrigger, "sync should be false immediately after trigger");
        }
    }

    function test_consecutiveSyncCycles() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        address forwarder = makeAddr("cycleForwarder");
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        syncTrigger.setForwarder(forwarder);

        // Use a short delay to avoid CCIP StaleTokenPrice on double-warp;
        // delay enforcement is already tested by other tests.
        uint48 shortDelay = 60;
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        syncTrigger.setDelay(shortDelay);

        (uint256 maxNativeFee,) = syncTrigger.getMaxFees();

        // ── Cycle 1: accumulate WETH, wait delay, sync ──
        _provisionPoolAndAccumulateWeth(newPool, uint256(L2_SYNC_MIN_AMOUNT) + 1 ether);
        vm.warp(block.timestamp + shortDelay);

        {
            (bool needed, uint256 amount) = syncTrigger.shouldSync();
            assertTrue(needed, "cycle 1: sync should be needed");
            assertGt(amount, 0, "cycle 1: amount should be > 0");
        }

        vm.deal(address(syncTrigger), maxNativeFee);
        vm.prank(forwarder);
        syncTrigger.triggerSync();

        uint48 exec1 = syncTrigger.getLastExecution();
        assertEq(exec1, uint48(block.timestamp), "cycle 1: lastExecution should update");

        {
            (bool neededAfter,) = syncTrigger.shouldSync();
            assertFalse(neededAfter, "cycle 1: sync should be false right after trigger");
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
            (bool neededEarly,) = syncTrigger.shouldSync();
            assertFalse(neededEarly, "cycle 2: sync should be false before delay");
        }

        vm.warp(block.timestamp + shortDelay);

        {
            (bool needed, uint256 amount) = syncTrigger.shouldSync();
            assertTrue(needed, "cycle 2: sync should be needed");
            assertGt(amount, 0, "cycle 2: amount should be > 0");
        }

        uint256 poolWethBefore = IERC20(L2_WETH).balanceOf(address(newPool));
        vm.deal(address(syncTrigger), maxNativeFee);
        vm.prank(forwarder);
        syncTrigger.triggerSync();

        assertGt(syncTrigger.getLastExecution(), exec1, "cycle 2: lastExecution should advance past cycle 1");
        assertLt(IERC20(L2_WETH).balanceOf(address(newPool)), poolWethBefore, "cycle 2: pool WETH should decrease");
    }

    function test_syncTriggerRevertsWithInsufficientFees() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 stakeAmount = uint256(L2_SYNC_MIN_AMOUNT) + 1 ether;
        _provisionPoolAndAccumulateWeth(newPool, stakeAmount);

        address forwarder = makeAddr("feeTestForwarder");
        vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
        syncTrigger.setForwarder(forwarder);

        vm.warp(block.timestamp + L2_SYNC_DELAY);

        (bool syncNeeded,) = syncTrigger.shouldSync();
        assertTrue(syncNeeded, "sync should be needed");

        // The migration funds the trigger's fee float (production parity). Drain it so this test
        // exercises the float-ran-dry path: with a 0 balance, triggerSync must revert
        // when it tries to forward the native CCIP fee from its own balance.
        uint256 floatBalance = address(syncTrigger).balance;
        if (floatBalance > 0) {
            vm.prank(LIDO_L2_GOVERNANCE_EXECUTOR);
            syncTrigger.sweep(address(0), makeAddr("floatSink"), floatBalance);
        }
        assertEq(address(syncTrigger).balance, 0, "sync trigger should have no ETH");

        vm.prank(forwarder);
        vm.expectRevert();
        syncTrigger.triggerSync();
    }

    /// @dev Stage 2 must refuse a mis-wired or half-configured Stage 1 BEFORE any
    ///      irreversible write (oracle-pool repoint, SYNC_ROLE grant, admin revoke, ProxyAdmin
    ///      handover). Here Stage 1 is deployed correctly, but Stage 2 is handed a creReceiver the
    ///      trigger's forwarder does not point at — the precondition fails and nothing is mutated.
    function test_executeMigrationStepsRevertsOnMiswiredStage1() public {
        vm.selectFork(l2Fork);
        L2UpgradeConfig memory cfg =
            _defaultL2Config(INITIAL_OWNER, LIDO_L2_GOVERNANCE_EXECUTOR, lidoL2LiquidityOwner);

        PausableImmutableOraclePool newPool = _deployL2Pool(cfg);

        address creForwarder = makeAddr("creForwarder");
        vm.deal(LIDO_L2_GOVERNANCE_EXECUTOR, cfg.syncTriggerInitialFloat);
        vm.startPrank(LIDO_L2_GOVERNANCE_EXECUTOR);
        (address syncTrigger,) =
            deploySyncInfrastructure(cfg, LIDO_L2_GOVERNANCE_EXECUTOR, creForwarder, cfg.liquidityOwner);
        vm.stopPrank();

        // Call via `this.` so executeMigrationSteps runs as a single external call and the
        // precondition revert is caught atomically (expectRevert latches onto the next external call).
        address wrongReceiver = makeAddr("wrongReceiver");
        vm.expectRevert(abi.encodeWithSelector(L2UpgradePostConditionFailed.selector, "syncTrigger forwarder"));
        this.executeMigrationSteps(cfg, address(newPool), syncTrigger, wrongReceiver, creForwarder);
    }

    function test_syncTriggerNotTriggeredWhenBalanceBelowMinAfterDelay() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 amountBelowMin = uint256(L2_SYNC_MIN_AMOUNT) - 1;
        assertEq(
            _provisionPoolAndAccumulateWeth(newPool, amountBelowMin),
            amountBelowMin,
            "pool should have WETH below min threshold"
        );

        (bool syncNeeded,) = _shouldSyncAfterDelay(syncTrigger);
        assertFalse(syncNeeded, "sync should stay false when balance is below min");
    }

    function test_syncTriggerTriggersAtExactMinAmount() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 exactMinAmount = uint256(L2_SYNC_MIN_AMOUNT);
        assertEq(
            _provisionPoolAndAccumulateWeth(newPool, exactMinAmount), exactMinAmount, "pool should have exact min WETH"
        );

        (bool syncNeeded, uint256 amount) = _shouldSyncAfterDelay(syncTrigger);
        assertTrue(syncNeeded, "sync should trigger at exact min amount");
        assertEq(amount, exactMinAmount, "amount should be the exact min amount");
    }

    function test_syncTriggerCapsAtMaxAmount() public {
        (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger) = _deployAndLoadSyncTrigger();

        uint256 balanceAboveMax = uint256(L2_SYNC_MAX_AMOUNT) + 1 ether;
        deal(L2_WETH, address(newPool), balanceAboveMax);

        (bool syncNeeded, uint256 amount) = _shouldSyncAfterDelay(syncTrigger);
        assertTrue(syncNeeded, "sync should trigger when balance is above max");
        assertEq(amount, uint256(L2_SYNC_MAX_AMOUNT), "amount should cap at max");
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
            makeAddr("creForwarder"),
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

    /// @dev Production-parity float provenance test: the first post-migration sync must succeed
    ///      funded ONLY by the float the deploy script itself put on the SyncTrigger. Deliberately
    ///      no `vm.deal(address(syncTrigger), …)` here — that out-of-band funding in the other
    ///      sync tests is exactly what masked an unfunded production trigger (the negative case,
    ///      `test_syncTriggerRevertsWithInsufficientFees`, proves the revert; this proves the
    ///      production recipe prevents it).
    function test_productionDeployFundsSyncTriggerFloatForFirstSync() public {
        (PausableImmutableOraclePool newPool, address newSyncTrigger, CREReceiver newCREReceiver) =
            _deployAndMigrateL2Production();
        ISyncTrigger syncTrigger = ISyncTrigger(newSyncTrigger);

        // Accounting: the deploy funded exactly the configured constant.
        L2UpgradeConfig memory cfg =
            _defaultL2Config(INITIAL_OWNER, LIDO_L2_GOVERNANCE_EXECUTOR, lidoL2LiquidityOwner);
        uint256 initialFloat = cfg.syncTriggerInitialFloat;
        assertEq(newSyncTrigger.balance, initialFloat, "deploy should fund exactly the configured float");

        // Floor invariant: the float covers at least one worst-case sync (mirrors fundSyncTrigger's guard).
        (uint256 maxNativeFee, uint256 maxLinkFee) = syncTrigger.getMaxFees();
        assertEq(maxLinkFee, 0, "no LINK leg expected in current config");
        assertGe(initialFloat, maxNativeFee, "float must cover one worst-case sync");

        _provisionPoolAndAccumulateWeth(newPool, uint256(L2_SYNC_MIN_AMOUNT) + 1 ether);
        vm.warp(block.timestamp + L2_SYNC_DELAY);

        (bool syncNeeded,) = syncTrigger.shouldSync();
        assertTrue(syncNeeded, "sync should be needed");

        // First sync, paid solely from the script-funded float (forwarder = CREReceiver in production wiring).
        vm.prank(address(newCREReceiver));
        syncTrigger.triggerSync();

        // Refund mechanics: the float drains by the actual fee only; the maxFee excess refunds to the trigger.
        assertLt(newSyncTrigger.balance, initialFloat, "sync should spend from the float");
        assertGt(newSyncTrigger.balance, initialFloat - maxNativeFee, "maxFee excess should refund to the trigger");
    }

    // ──────────────── Internal test helpers ──────────────────────────────

    function _deployAndLoadSyncTrigger()
        internal
        returns (PausableImmutableOraclePool newPool, ISyncTrigger syncTrigger)
    {
        address syncTriggerAddress;
        (newPool, syncTriggerAddress) = _deployAndMigrateL2WithSyncTrigger();
        syncTrigger = ISyncTrigger(syncTriggerAddress);
    }

    function _shouldSyncAfterDelay(ISyncTrigger syncTrigger)
        internal
        returns (bool syncNeeded, uint256 amount)
    {
        vm.warp(block.timestamp + L2_SYNC_DELAY);
        (syncNeeded, amount) = syncTrigger.shouldSync();
    }
}
