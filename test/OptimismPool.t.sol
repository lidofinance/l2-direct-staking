// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {PoolTestBase} from "test/helpers/PoolTestBase.sol";
import {OptimismPoolTestBase} from "test/helpers/OptimismPoolTestBase.sol";
import {PoolTests} from "test/helpers/PoolTests.sol";

/**
 * @title OptimismPoolTest
 * @notice Fork-based test harness that checks Lido Direct Staking pool behavior on Optimism.
 * @dev Inherits all shared pool tests from PoolTests,
 *      configured with Optimism constants via OptimismPoolTestBase.
 */
contract OptimismPoolTest is OptimismPoolTestBase, PoolTests {
    function setUp() public override(OptimismPoolTestBase, PoolTestBase) {
        OptimismPoolTestBase.setUp();
    }
}
