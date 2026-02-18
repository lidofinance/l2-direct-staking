// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {UpgradeTestBase} from "test/helpers/UpgradeTestBase.sol";
import {OptimismUpgradeTestBase} from "test/helpers/OptimismUpgradeTestBase.sol";
import {PoolUpgradeTests} from "test/helpers/PoolUpgradeTests.sol";

/**
 * @title OptimismPoolUpgradeTest
 * @notice Fork-based test harness that simulates the Lido Direct Staking pool migration on Optimism.
 * @dev Inherits all shared pool upgrade tests from PoolUpgradeTests,
 *      configured with Optimism constants via OptimismUpgradeTestBase.
 */
contract OptimismPoolUpgradeTest is OptimismUpgradeTestBase, PoolUpgradeTests {
    function setUp() public override(OptimismUpgradeTestBase, UpgradeTestBase) {
        OptimismUpgradeTestBase.setUp();
    }
}
