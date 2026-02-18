/**
 * ABI for SyncTrigger contract (shouldSync / triggerSync).
 */
export const SyncTriggerABI = [
  {
    inputs: [],
    name: "shouldSync",
    outputs: [
      { internalType: "bool", name: "syncNeeded", type: "bool" },
      { internalType: "uint256", name: "amount", type: "uint256" },
    ],
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
