// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {UpgradeTestBase} from "test/helpers/UpgradeTestBase.sol";
import {OptimismUpgradeTestBase} from "test/helpers/OptimismUpgradeTestBase.sol";
import {ArbitrumUpgradeTestBase} from "test/helpers/ArbitrumUpgradeTestBase.sol";
import {BaseUpgradeTestBase} from "test/helpers/BaseUpgradeTestBase.sol";
import {LineaUpgradeTestBase} from "test/helpers/LineaUpgradeTestBase.sol";
import {CREIntegrationTests} from "test/helpers/CREIntegrationTests.sol";

/**
 * @title CRE integration tests — one concrete suite per L2 network.
 * @dev Each suite inherits all 8 shared CRE tests from CREIntegrationTests,
 *      configured with network-specific constants via the UpgradeTestBase.
 */
contract OptimismCREIntegrationTest is OptimismUpgradeTestBase, CREIntegrationTests {
    function setUp() public override(OptimismUpgradeTestBase, UpgradeTestBase) {
        OptimismUpgradeTestBase.setUp();
    }
}

contract ArbitrumCREIntegrationTest is ArbitrumUpgradeTestBase, CREIntegrationTests {
    function setUp() public override(ArbitrumUpgradeTestBase, UpgradeTestBase) {
        ArbitrumUpgradeTestBase.setUp();
    }
}

contract BaseCREIntegrationTest is BaseUpgradeTestBase, CREIntegrationTests {
    function setUp() public override(BaseUpgradeTestBase, UpgradeTestBase) {
        BaseUpgradeTestBase.setUp();
    }
}

contract LineaCREIntegrationTest is LineaUpgradeTestBase, CREIntegrationTests {
    function setUp() public override(LineaUpgradeTestBase, UpgradeTestBase) {
        LineaUpgradeTestBase.setUp();
    }
}
