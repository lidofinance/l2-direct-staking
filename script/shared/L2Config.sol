// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";

/// @notice Lane parameters and fee encoding shared by fork fixtures and configuration checks.
contract L2Config {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant SYNC_ROLE = keccak256("SYNC_ROLE");

    struct LaneConfig {
        address liquidityOwner;
        address customSender;
        address tokenIn;
        address tokenOut;
        address priceOracle;
        uint96 fee;
        uint64 destChainSelector;
        uint128 destinationMaxFee;
        uint32 destinationGasLimit;
        uint32 maxGasLimit;
        bytes feeDtoO;
        uint128 minSyncAmount;
        uint128 maxSyncAmount;
        uint48 minSyncDelay;
    }

    function _encodeFeeOtoD(LaneConfig memory cfg) internal pure returns (bytes memory) {
        // payInLink hardcoded false — LINK fee payment is not supported (SyncTrigger rejects payInLink).
        return FeeCodec.encodeCCIP(cfg.destinationMaxFee, false, cfg.destinationGasLimit);
    }

    function _maxFees(bytes memory feeOtoD, bytes memory feeDtoO) internal pure returns (uint256 maxNativeFee) {
        (uint256 maxFeeOtoD,) = FeeCodec.decodeFeeMemory(feeOtoD);
        (uint256 maxFeeDtoO,) = FeeCodec.decodeFeeMemory(feeDtoO);
        maxNativeFee = maxFeeOtoD + maxFeeDtoO;
    }
}
