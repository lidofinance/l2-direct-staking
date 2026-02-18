// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {UpgradeTestBase} from "test/helpers/UpgradeTestBase.sol";
import {BaseUpgradeTestBase} from "test/helpers/BaseUpgradeTestBase.sol";
import {PoolUpgradeTests} from "test/helpers/PoolUpgradeTests.sol";

/**
 * @title BasePoolUpgradeTest
 * @notice Fork-based test harness that simulates the Lido Direct Staking pool migration on Base.
 * @dev Inherits all shared pool upgrade tests from PoolUpgradeTests,
 *      configured with Base constants via BaseUpgradeTestBase.
 */
contract BasePoolUpgradeTest is BaseUpgradeTestBase, PoolUpgradeTests {
    function setUp() public override(BaseUpgradeTestBase, UpgradeTestBase) {
        BaseUpgradeTestBase.setUp();
    }
}
