// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {PoolTestBase} from "test/helpers/PoolTestBase.sol";
import {BasePoolTestBase} from "test/helpers/BasePoolTestBase.sol";
import {PoolTests} from "test/helpers/PoolTests.sol";

/**
 * @title BasePoolTest
 * @notice Fork-based test harness that checks Lido Direct Staking pool behavior on Base.
 * @dev Inherits all shared pool tests from PoolTests,
 *      configured with Base constants via BasePoolTestBase.
 */
contract BasePoolTest is BasePoolTestBase, PoolTests {
    function setUp() public override(BasePoolTestBase, PoolTestBase) {
        BasePoolTestBase.setUp();
    }
}
