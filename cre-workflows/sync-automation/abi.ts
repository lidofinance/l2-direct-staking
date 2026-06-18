/**
 * ABI for SyncTrigger contract (shouldSync / canSync / getAmountToSync / triggerSync).
 */
export const SyncTriggerABI = [
  {
    inputs: [],
    name: "shouldSync",
    outputs: [{ internalType: "bool", name: "", type: "bool" }],
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
    name: "getAmountToSync",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
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
