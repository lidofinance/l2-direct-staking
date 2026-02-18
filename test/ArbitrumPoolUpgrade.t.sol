// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {UpgradeTestBase} from "test/helpers/UpgradeTestBase.sol";
import {ArbitrumUpgradeTestBase} from "test/helpers/ArbitrumUpgradeTestBase.sol";
import {PoolUpgradeTests} from "test/helpers/PoolUpgradeTests.sol";

/**
 * @title ArbitrumPoolUpgradeTest
 * @notice Fork-based test harness that simulates the Lido Direct Staking pool migration on Arbitrum.
 * @dev Inherits all shared pool upgrade tests from PoolUpgradeTests,
 *      configured with Arbitrum constants via ArbitrumUpgradeTestBase.
 */
contract ArbitrumPoolUpgradeTest is ArbitrumUpgradeTestBase, PoolUpgradeTests {
    function setUp() public override(ArbitrumUpgradeTestBase, UpgradeTestBase) {
        ArbitrumUpgradeTestBase.setUp();
    }
}
