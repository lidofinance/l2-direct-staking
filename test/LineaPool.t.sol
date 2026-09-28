// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {PoolTestBase} from "test/helpers/PoolTestBase.sol";
import {LineaPoolTestBase} from "test/helpers/LineaPoolTestBase.sol";
import {PoolTests} from "test/helpers/PoolTests.sol";

/**
 * @title LineaPoolTest
 * @notice Fork-based test harness that checks Lido Direct Staking pool behavior on Linea.
 * @dev Inherits all shared pool tests from PoolTests,
 *      configured with Linea constants via LineaPoolTestBase.
 */
contract LineaPoolTest is LineaPoolTestBase, PoolTests {
    function setUp() public override(LineaPoolTestBase, PoolTestBase) {
        LineaPoolTestBase.setUp();
    }
}
