#!/bin/sh
# UNCAGED Index Relay — container entrypoint.
#
# First-run experience: when NOSTR_NSEC is unset, generate a fresh relay
# signing key, print it ONCE (so the operator can back it up / publish the
# relay's pubkey), and persist it to $RELAY_DATA_DIR/relay-secret.env so it
# survives container restarts. On later runs the persisted key is reused.
#
# The relay needs a signing key for trends and NIP-85 assertions — nothing
# else about the SIP-01 index depends on it, so an ephemeral key is fine
# for a home/umbrel deployment that just wants to serve the index.
set -e

DATA_DIR="${RELAY_DATA_DIR:-/app/data}"
SECRET_FILE="$DATA_DIR/relay-secret.env"

mkdir -p "$DATA_DIR" 2>/dev/null || true

persist_key() {
  if echo "NOSTR_NSEC=$1" > "$SECRET_FILE" 2>/dev/null; then
    chmod 600 "$SECRET_FILE" 2>/dev/null || true
    echo "uncaged: relay signing key persisted at $SECRET_FILE"
  else
    echo "uncaged: WARNING - could not persist key to $DATA_DIR (read-only?)."
    echo "uncaged: The key will be regenerated on the next restart. Set"
    echo "uncaged: NOSTR_NSEC explicitly, or fix the volume permissions."
  fi
}

if [ -n "$NOSTR_NSEC" ]; then
  # Operator-provided key (env var wins; nothing to do).
  echo "uncaged: using NOSTR_NSEC from environment"
elif [ -f "$SECRET_FILE" ]; then
  # Reuse the key generated on a previous run.
  echo "uncaged: reusing persisted relay signing key"
  # shellcheck disable=SC1090
  . "$SECRET_FILE"
  export NOSTR_NSEC
else
  # First run: generate a key with the bundled Bun runtime (nostr-tools is
  # already installed in /app/node_modules — run from the app dir).
  NSEC=$(cd /app && bun -e "const {nip19, generateSecretKey} = require('nostr-tools'); console.log(nip19.nsecEncode(generateSecretKey()))" 2>/dev/null || true)

  if [ -n "$NSEC" ] && [ "${NSEC#nsec1}" != "$NSEC" ]; then
    export NOSTR_NSEC="$NSEC"
    persist_key "$NSEC"
    echo "uncaged: generated a NEW relay signing key - BACK IT UP NOW (printed once):"
    echo "  $NSEC"
  else
    echo "uncaged: could not auto-generate a signing key; set NOSTR_NSEC manually" >&2
    exit 1
  fi
fi

exec "$@"
