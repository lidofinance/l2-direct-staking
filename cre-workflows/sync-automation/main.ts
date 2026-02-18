/**
 * Lido Direct Staking — CRE Sync Workflow
 *
 * Triggers periodic sync of accumulated L2 WETH to L1 for Lido staking.
 *
 * Flow:
 *   CronCapability trigger → read shouldSync() → if needed, encode triggerSync() →
 *   sign report → write to CREReceiver → SyncTrigger.triggerSync() →
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
import { zeroAddress } from "viem";
import {
  encodeReportPayload,
  decodeShouldSyncResult,
  encodeShouldSyncCall,
} from "./encoding";

// ─── Config ────────────────────────────────────────────────────────────────

const configSchema = z.object({
  /** CREReceiver contract address on the target chain */
  receiverAddress: z.string(),
  /** CRE chain selector name (e.g. "ethereum-mainnet-optimism-1") */
  chainSelectorName: z.string(),
  /** Gas limit for the on-chain write transaction */
  writeGasLimit: z.string(),
  /** SyncTrigger contract address (shouldSync/triggerSync target) */
  targetAddress: z.string(),
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

  // 2. Read shouldSync from SyncTrigger
  runtime.log("Calling shouldSync...");

  const callData = encodeShouldSyncCall();

  const contractCall = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to: config.targetAddress as `0x${string}`,
        data: callData,
      }),
      blockNumber: LATEST_BLOCK_NUMBER,
    })
    .result();

  const checkResult = decodeShouldSyncResult(bytesToHex(contractCall.data));

  runtime.log(`syncNeeded=${checkResult.syncNeeded} amount=${checkResult.amount}`);

  // 3. Exit early if no action needed
  if (!checkResult.syncNeeded) {
    runtime.log("No sync needed, skipping.");
    return "no-action";
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

  const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32));
  runtime.log(`txHash=${txHash} status=${writeResult.txStatus}`);

  if (writeResult.txStatus === TxStatus.SUCCESS) {
    runtime.log("=== Sync Workflow Completed ===");
    return txHash;
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
