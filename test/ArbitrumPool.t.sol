// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {PoolTestBase} from "test/helpers/PoolTestBase.sol";
import {ArbitrumPoolTestBase} from "test/helpers/ArbitrumPoolTestBase.sol";
import {PoolTests} from "test/helpers/PoolTests.sol";

/**
 * @title ArbitrumPoolTest
 * @notice Fork-based test harness that checks Lido Direct Staking pool behavior on Arbitrum.
 * @dev Inherits all shared pool tests from PoolTests,
 *      configured with Arbitrum constants via ArbitrumPoolTestBase.
 */
contract ArbitrumPoolTest is ArbitrumPoolTestBase, PoolTests {
    function setUp() public override(ArbitrumPoolTestBase, PoolTestBase) {
        ArbitrumPoolTestBase.setUp();
    }
}
