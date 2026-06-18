/**
 * Lido Direct Staking — CRE Sync Workflow
 *
 * Triggers periodic sync of accumulated L2 WETH to L1 for Lido staking.
 *
 * Flow:
 *   CronCapability trigger → read shouldSync() (due?) + canSync() (executable?) → if both, encode
 *   triggerSync() → sign report → write to CREReceiver → SyncTrigger.triggerSync() →
 *   CustomSender.sync() → CCIP → L1
 */

import {
  cre,
  EVMClient,
  getNetwork,
  hexToBase64,
  bytesToHex,
  TxStatus,
  type Runtime,
  Runner,
  encodeCallMsg,
  LATEST_BLOCK_NUMBER,
} from "@chainlink/cre-sdk";
import { z } from "zod";
import { isAddress, zeroAddress, type Hex } from "viem";
import {
  encodeReportPayload,
  encodeShouldSyncCall,
  decodeShouldSyncResult,
  encodeCanSyncCall,
  decodeCanSyncResult,
  encodeAmountToSyncCall,
  decodeAmountToSyncResult,
  decideSyncAction,
} from "./encoding";

// ─── Config ────────────────────────────────────────────────────────────────

// reject placeholders ("0xYOUR_..."), typos, and the zero address at config-validation time —
// a bare z.string() lets them through, and they then fail only inside the DON at runtime
// (viem throws on encode / the eth_call hits an empty account), a silent permanent no-sync.
const evmAddress = z
  .string()
  .refine((a) => isAddress(a, { strict: false }) && a.toLowerCase() !== zeroAddress, {
    message: "must be a 0x-prefixed 20-byte hex EVM address",
  });

const configSchema = z.object({
  /** CREReceiver contract address on the target chain */
  receiverAddress: evmAddress,
  /** CRE chain selector name (e.g. "ethereum-mainnet-optimism-1") */
  chainSelectorName: z.string(),
  /** Gas limit for the on-chain write transaction */
  writeGasLimit: z.string(),
  /** SyncTrigger contract address (shouldSync/triggerSync target) */
  targetAddress: evmAddress,
  // Cron schedule for polling (e.g. "0 */5 * * * *" = every 5 minutes)
  schedule: z.string(),
});

type Config = z.infer<typeof configSchema>;

// ─── Workflow handler ──────────────────────────────────────────────────────

const onCronTrigger = (runtime: Runtime<Config>): string => {
  const config = runtime.config;

  runtime.log("=== Lido Sync Workflow Started ===");
  runtime.log(`Target: ${config.targetAddress} on ${config.chainSelectorName}`);

  // 1. Resolve network
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: config.chainSelectorName,
  });

  if (!network) {
    throw new Error(`Network not found: ${config.chainSelectorName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);

  // 2. Probe the two on-chain predicates the DON gates on. A sync proceeds only when it is both DUE
  //    (shouldSync: delay elapsed + pool WETH >= minAmount) AND executable (canSync: the fee float,
  //    SYNC_ROLE, and pool-pause preconditions that would otherwise make triggerSync revert). Splitting
  //    them lets the DON suppress a due-but-blocked tick (a silent, signalless stall surfaced off-chain)
  //    instead of submitting a guaranteed-revert report every tick.
  const staticCall = (data: Hex): Hex => {
    const res = evmClient
      .callContract(runtime, {
        call: encodeCallMsg({
          from: zeroAddress,
          to: config.targetAddress as `0x${string}`,
          data,
        }),
        blockNumber: LATEST_BLOCK_NUMBER,
      })
      .result();
    return bytesToHex(res.data);
  };

  runtime.log("Calling shouldSync (is a sync due?)...");
  const due = decodeShouldSyncResult(staticCall(encodeShouldSyncCall()));

  // Only probe executability + amount when a sync is actually due — saves two eth_calls on idle ticks.
  const executable = due ? decodeCanSyncResult(staticCall(encodeCanSyncCall())) : false;
  const amount = due ? decodeAmountToSyncResult(staticCall(encodeAmountToSyncCall())) : 0n;

  runtime.log(`due=${due} executable=${executable} amount=${amount}`);

  // 3. Route the tick. `decideSyncAction` (pure, unit-tested) maps the two predicates to one of three
  //    terminal branches; only "execute" proceeds to the report path below. "blocked" (due but an
  //    executability precondition is unmet — float / SYNC_ROLE / pool pause) skips rather than submit a
  //    guaranteed-revert report (the stall off-chain monitoring surfaces); "no-action" is simply not
  //    due. A mis-route of a blocked tick into the report path is the exact DON spam this split
  //    prevents — hence the routing lives in a tested pure function.
  const action = decideSyncAction({ due, executable });
  if (action !== "execute") {
    if (action === "blocked") {
      runtime.log(
        `Sync due (amount=${amount}) but not currently executable — skipping. ` +
          "Check trigger float, SYNC_ROLE, and pool pause.",
      );
    } else {
      runtime.log("No sync needed, skipping.");
    }
    return action;
  }

  // 4. Encode triggerSync report for CREReceiver
  runtime.log("Sync needed — encoding triggerSync report...");
  const reportPayload = encodeReportPayload(config.targetAddress);

  // 5. Sign and send report
  runtime.log("Signing report...");
  const reportResponse = runtime
    .report({
      encodedPayload: hexToBase64(reportPayload),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result();

  runtime.log("Writing report to CREReceiver...");
  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: config.receiverAddress,
      report: reportResponse,
      gasConfig: { gasLimit: config.writeGasLimit },
    })
    .result();

  const rawTxHash = writeResult.txHash;
  runtime.log(
    `txHash=${rawTxHash && rawTxHash.length > 0 ? bytesToHex(rawTxHash) : "<none>"} status=${writeResult.txStatus}`,
  );

  if (writeResult.txStatus === TxStatus.SUCCESS) {
    // Never substitute an all-zero hash: a SUCCESS with no txHash reported as 0x000…000 is a hash
    // off-chain monitors would chase on-chain, find nothing at, and then either false-alarm on or
    // silently drop — a blind spot for every successful-but-unmined sync. Fail loudly instead.
    if (!rawTxHash || rawTxHash.length === 0) {
      throw new Error(`writeReport reported SUCCESS (status=${writeResult.txStatus}) but returned no txHash`);
    }
    runtime.log("=== Sync Workflow Completed ===");
    return bytesToHex(rawTxHash);
  }

  throw new Error(`Transaction failed: status=${writeResult.txStatus}`);
};

// ─── Entry point ───────────────────────────────────────────────────────────

const initWorkflow = (config: Config) => {
  return [
    cre.handler(
      new cre.capabilities.CronCapability().trigger({
        schedule: config.schedule,
      }),
      onCronTrigger,
    ),
  ];
};

export async function main() {
  const runner = await Runner.newRunner<Config>({ configSchema });
  await runner.run(initWorkflow);
}

main();
