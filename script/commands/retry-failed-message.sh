#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

die() {
  echo "$*" >&2
  exit 1
}

tx="${1:-}"
mode="${2:-dry-run}"
selected_id="${3:-}"
if [[ $# -lt 1 || $# -gt 3 || ! "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  die "Usage: just retry-failed-message <L1-tx> [dry-run|send] [message-id]"
fi
if [[ "$mode" != dry-run && "$mode" != send ]]; then
  die "Mode must be dry-run or send"
fi
if [[ -n "$selected_id" && ! "$selected_id" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  die "message-id must be a 32-byte hex value"
fi

for command in cast jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    die "$command is required"
  fi
done

source script/shared/cre-env.sh
rpc="$(resolve_l1_rpc)"
chain_id="$(cast chain-id --rpc-url "$rpc")"
if [[ "$chain_id" != 1 ]]; then
  die "Expected Ethereum mainnet (chain 1), got $chain_id"
fi

# L1MigrationConstants.L1_LIDO_CUSTOM_RECEIVER; only this receiver's events qualify.
receiver=0x6F357d53d6bE3238180316BA5F8f11467e164588
signature='retryFailedMessage((bytes32,uint64,bytes,bytes,(address,uint256)[]))'
topic="$(cast keccak 'MessageFailed(bytes32,(bytes32,uint64,bytes,bytes,(address,uint256)[]))')"
receipt="$(cast rpc --rpc-url "$rpc" eth_getTransactionReceipt "$tx")"
if ! jq -e --arg tx "$tx" '
  .status == "0x1" and
  (.transactionHash | ascii_downcase) == ($tx | ascii_downcase) and
  (.logs | type) == "array"
' <<<"$receipt" >/dev/null; then
  die "Transaction receipt is missing, reverted, or does not match the requested transaction"
fi

logs="$(jq -c --arg receiver "$receiver" --arg topic "$topic" --arg id "$selected_id" '
  [.logs[] | select(
    (.address | ascii_downcase) == ($receiver | ascii_downcase) and
    .topics[0] == $topic and
    ($id == "" or (.topics[1] | ascii_downcase) == ($id | ascii_downcase))
  )]
' <<<"$receipt")"
count="$(jq 'length' <<<"$logs")"
if [[ "$count" == 0 ]]; then
  die "No matching MessageFailed event from the L1 receiver"
fi
if [[ "$count" != 1 ]]; then
  echo "Multiple failures; select a message-id:" >&2
  jq -r '.[].topics[1]' <<<"$logs" >&2
  exit 1
fi

message_id="$(jq -er '.[0].topics[1]' <<<"$logs")"
data="$(jq -er '.[0].data' <<<"$logs")"
if [[ ! "$message_id" =~ ^0x[0-9a-fA-F]{64}$ || ! "$data" =~ ^0x([0-9a-fA-F]{2})+$ ]]; then
  die "Malformed MessageFailed event"
fi
decoded="$(cast decode-abi --input --json "$signature" "$data")"
if ! jq -e --arg id "$message_id" '.[0][0] | ascii_downcase == ($id | ascii_downcase)' \
  <<<"$decoded" >/dev/null; then
  die "MessageFailed topic and payload message IDs differ"
fi

stored_hash="$(cast call --rpc-url "$rpc" "$receiver" 'getFailedMessageHash(bytes32)(bytes32)' "$message_id")"
stored_hash="$(printf '%s' "$stored_hash" | tr 'A-F' 'a-f')"
if [[ "$stored_hash" == "0x$(printf '%064d' 0)" ]]; then
  die "Message is no longer stored on L1 (already retried or recovered)"
fi
message_hash="$(cast keccak "$data")"
if [[ "$stored_hash" != "$message_hash" ]]; then
  die "Event payload does not match the receiver's stored message hash"
fi

# Event data is abi.encode(message), exactly the argument bytes expected by retryFailedMessage.
selector="$(cast sig "$signature")"
calldata="$selector${data#0x}"
sender="${ETH_FROM:-0x0000000000000000000000000000000000000000}"
if [[ "$mode" == send && -z "${RETRY_PRIVATE_KEY:-}" ]]; then
  die "Set RETRY_PRIVATE_KEY for the account that will pay L1 gas"
fi
if [[ -n "${RETRY_PRIVATE_KEY:-}" ]]; then
  sender="$(cast wallet address --private-key "$RETRY_PRIVATE_KEY" 2>/dev/null)" ||
    die "Invalid RETRY_PRIVATE_KEY"
fi

echo "Ethereum mainnet · receiver $receiver · message $message_id" >&2
cast call --rpc-url "$rpc" --from "$sender" "$receiver" --data "$calldata" >/dev/null
if [[ "$mode" == dry-run ]]; then
  echo "Simulation passed from $sender. No transaction sent." >&2
  printf '%s\n' "$calldata"
else
  echo "Simulation passed. Sending from $sender." >&2
  cast send --rpc-url "$rpc" --private-key "$RETRY_PRIVATE_KEY" --from "$sender" "$receiver" "$calldata"
fi
