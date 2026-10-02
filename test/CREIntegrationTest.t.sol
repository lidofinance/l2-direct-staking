// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {PoolTestBase} from "test/helpers/PoolTestBase.sol";
import {OptimismPoolTestBase} from "test/helpers/OptimismPoolTestBase.sol";
import {ArbitrumPoolTestBase} from "test/helpers/ArbitrumPoolTestBase.sol";
import {BasePoolTestBase} from "test/helpers/BasePoolTestBase.sol";
import {LineaPoolTestBase} from "test/helpers/LineaPoolTestBase.sol";
import {CREIntegrationTests} from "test/helpers/CREIntegrationTests.sol";

/**
 * @title CRE integration tests — one concrete suite per L2 network.
 * @dev Each suite inherits the shared CRE tests from CREIntegrationTests,
 *      configured with network-specific constants via the PoolTestBase.
 */
contract OptimismCREIntegrationTest is OptimismPoolTestBase, CREIntegrationTests {
    function setUp() public override(OptimismPoolTestBase, PoolTestBase) {
        OptimismPoolTestBase.setUp();
    }
}

contract ArbitrumCREIntegrationTest is ArbitrumPoolTestBase, CREIntegrationTests {
    function setUp() public override(ArbitrumPoolTestBase, PoolTestBase) {
        ArbitrumPoolTestBase.setUp();
    }
}

contract BaseCREIntegrationTest is BasePoolTestBase, CREIntegrationTests {
    function setUp() public override(BasePoolTestBase, PoolTestBase) {
        BasePoolTestBase.setUp();
    }
}

contract LineaCREIntegrationTest is LineaPoolTestBase, CREIntegrationTests {
    function setUp() public override(LineaPoolTestBase, PoolTestBase) {
        LineaPoolTestBase.setUp();
    }
}
