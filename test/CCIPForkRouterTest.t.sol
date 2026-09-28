// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {CCIPForkRouter} from "test/helpers/CCIPForkRouter.sol";

contract CCIPForkRouterTest is CCIPForkRouter {
    address private constant ON_RAMP = address(0x1234);

    function routeFormat() external view returns (bool) {
        return _isV16OnRamp(ON_RAMP);
    }

    function test_v15EventFormat() public {
        _mockVersion("EVM2EVMOnRamp 1.5.0");
        assertFalse(this.routeFormat());
    }

    function test_v16EventFormat() public {
        _mockVersion("OnRamp 1.6.0");
        assertTrue(this.routeFormat());
        _mockVersion("OnRamp 1.6.1");
        assertTrue(this.routeFormat());
    }

    function test_rejectsUnsupportedEventFormat() public {
        _mockVersion("OnRamp 2.0.0");
        vm.expectRevert(abi.encodeWithSelector(UnsupportedOnRampVersion.selector, "OnRamp 2.0.0"));
        this.routeFormat();
    }

    function _mockVersion(string memory version) private {
        vm.mockCall(ON_RAMP, abi.encodeWithSignature("typeAndVersion()"), abi.encode(version));
    }
}
