/**
 * ABI for SyncTrigger contract (shouldSyncAmount / canSync / triggerSync).
 */
export const SyncTriggerABI = [
  {
    inputs: [],
    name: "shouldSyncAmount",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "canSync",
    outputs: [{ internalType: "bool", name: "", type: "bool" }],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "triggerSync",
    outputs: [],
    stateMutability: "nonpayable",
    type: "function",
  },
] as const;
