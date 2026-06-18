// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {FeeCodec} from "@csr/libraries/FeeCodec.sol";

/**
 * @title FeeSplit
 * @notice Splits the SyncTrigger OtoD/DtoO fee blobs into their max native- and LINK-denominated
 *         totals.
 * @dev Extracted so {SyncTrigger.getMaxFees} and the deploy script's `runPrintFeeParams` — the oracle
 *      `just verify-constants-sync` validates the `<net>.inputs.yaml` fee anchors against — share ONE
 *      definition of the fee-denomination split and cannot drift apart. A change to the split semantics
 *      now has to be made here once, rather than kept byte-identical in two places.
 */
library FeeSplit {
    /**
     * @dev Sums each leg's `maxFee` into the native or LINK total per that leg's `payInLink` flag.
     *      `feeOtoD` / `feeDtoO` are the same buffers the SyncTrigger setters validate (CCIP 21-byte /
     *      `decodeFee` >= 17-byte); `decodeFeeMemory` reads the first 17 bytes (maxFee[0:16] +
     *      payInLink[16]). Reverts (FeeCodecInvalidDataLength) on a buffer shorter than 17 bytes, so
     *      callers must guard empty/unset blobs before calling.
     */
    function maxFees(bytes memory feeOtoD, bytes memory feeDtoO)
        internal
        pure
        returns (uint256 maxNativeFee, uint256 maxLinkFee)
    {
        (uint256 maxFeeOtoD, bool payInLinkOtoD) = FeeCodec.decodeFeeMemory(feeOtoD);
        if (payInLinkOtoD) maxLinkFee = maxFeeOtoD;
        else maxNativeFee = maxFeeOtoD;

        (uint256 maxFeeDtoO, bool payInLinkDtoO) = FeeCodec.decodeFeeMemory(feeDtoO);
        if (payInLinkDtoO) maxLinkFee += maxFeeDtoO;
        else maxNativeFee += maxFeeDtoO;
    }
}
