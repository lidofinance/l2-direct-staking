// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {UpgradeTestBase} from "test/helpers/UpgradeTestBase.sol";
import {LineaUpgradeTestBase} from "test/helpers/LineaUpgradeTestBase.sol";
import {PoolUpgradeTests} from "test/helpers/PoolUpgradeTests.sol";

/**
 * @title LineaPoolUpgradeTest
 * @notice Fork-based test harness that simulates the Lido Direct Staking pool migration on Linea.
 * @dev Inherits all shared pool upgrade tests from PoolUpgradeTests,
 *      configured with Linea constants via LineaUpgradeTestBase.
 */
contract LineaPoolUpgradeTest is LineaUpgradeTestBase, PoolUpgradeTests {
    function setUp() public override(LineaUpgradeTestBase, UpgradeTestBase) {
        LineaUpgradeTestBase.setUp();
    }
}
