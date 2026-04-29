# Justfile for Midnight Node
#
# Build, test, and chainspec generation tasks. These recipes use the nix-based
# build (see flake.nix) and replace what the Earthfile previously did. The E2E
# test recipes near the bottom still call shell scripts that drive Docker.

# Networks that can be regenerated. mainnet/preview/preprod are excluded
# because their genesis is meant to be set once and not reset.
rebuildable_networks := "undeployed devnet qanet govnet perfnet guardnet"
all_networks := "undeployed devnet qanet preview preprod mainnet govnet guardnet perfnet"

# ----- nix build shortcuts -----

# Build the node binary
build:
  nix build .#midnight-node

# Build the toolkit binary
build-toolkit:
  nix build .#midnight-node-toolkit

# Build the runtime WASM blob
build-wasm:
  nix build .#wasmRuntime

# Build the OCI image (.tar.gz under ./result)
build-node-oci:
  nix build .#midnight-node-oci

build-toolkit-oci:
  nix build .#midnight-node-toolkit-oci

# Build everything that goes into a release
build-all:
  nix build .#midnight-node .#midnight-node-toolkit .#wasmRuntime .#midnight-node-oci .#midnight-node-toolkit-oci

# ----- chainspec / genesis generation -----

# Generate the ledger genesis state for a network.
#
# Mirrors the Earthfile +rebuild-genesis-state target. Reads chain config from
# res/<NETWORK>/ (or res/dev/ for `undeployed`) and writes the resulting .mn
# files into res/genesis/.
#
# FUND_FAUCET_WALLETS=true requires secrets/${NETWORK}-genesis-seeds.json. Use
# false (e.g. for mainnet) to skip faucet wallet funding.
generate-genesis-state NETWORK FUND_FAUCET_WALLETS="true":
  #!/usr/bin/env bash
  set -euo pipefail

  NETWORK="{{NETWORK}}"
  FUND="{{FUND_FAUCET_WALLETS}}"
  REPO_DIR="{{justfile_directory()}}"

  TOOLKIT_OUT=$(nix build .#midnight-node-toolkit --no-link --print-out-paths)
  TOOLKIT_BIN="$TOOLKIT_OUT/bin/midnight-node-toolkit"
  echo "Using toolkit: $TOOLKIT_BIN"

  # Pick config dir: undeployed reuses the dev configs.
  if [ "$NETWORK" = "undeployed" ]; then
    CFG_DIR="$REPO_DIR/res/dev"
  else
    CFG_DIR="$REPO_DIR/res/$NETWORK"
  fi

  if [ ! -d "$CFG_DIR" ]; then
    echo "Error: config directory not found: $CFG_DIR"
    exit 1
  fi

  WORKDIR=$(mktemp -d)
  trap "rm -rf $WORKDIR" EXIT
  cd "$WORKDIR"

  GENESIS_ARGS=(
    --network "$NETWORK"
    --ledger-parameters-config "$CFG_DIR/ledger-parameters-config.json"
    --cnight-generates-dust-config "$CFG_DIR/cnight-config.json"
    --ics-config "$CFG_DIR/ics-config.json"
  )
  if [ -f "$CFG_DIR/reserve-config.json" ]; then
    GENESIS_ARGS+=(--reserve-config "$CFG_DIR/reserve-config.json")
  fi
  if [ -f "$CFG_DIR/cardano-tip.json" ] && [ "$FUND" = "false" ]; then
    GENESIS_ARGS+=(--cardano-tip-config "$CFG_DIR/cardano-tip.json")
  fi

  SEEDS_FILE="$REPO_DIR/secrets/${NETWORK}-genesis-seeds.json"
  if [ "$FUND" = "true" ]; then
    if [ "$NETWORK" = "undeployed" ]; then
      # Reproduces the inline seeds the Earthfile generates for `undeployed`.
      cat > "$WORKDIR/genesis-seeds.json" <<'EOF'
  {
    "wallet-seed-0": "0000000000000000000000000000000000000000000000000000000000000001",
    "wallet-seed-1": "0000000000000000000000000000000000000000000000000000000000000002",
    "wallet-seed-2": "0000000000000000000000000000000000000000000000000000000000000003",
    "wallet-seed-3": "a51c86de32d0791f7cffc3bdff1abd9bb54987f0ed5effc30c936dddbb9afd9d530c8db445e4f2d3ea42a321b260e022aadf05987c9a67ec7b6b6ca1d0593ec9"
  }
  EOF
      GENESIS_ARGS+=(--seeds-file "$WORKDIR/genesis-seeds.json")
    elif [ -f "$SEEDS_FILE" ]; then
      GENESIS_ARGS+=(--seeds-file "$SEEDS_FILE")
      echo "Using seeds file: $SEEDS_FILE"
    else
      echo "Warning: FUND_FAUCET_WALLETS=true but no seeds file at $SEEDS_FILE"
      echo "Proceeding without faucet wallet funding."
    fi
  fi

  echo "Generating genesis state for $NETWORK..."
  "$TOOLKIT_BIN" generate-genesis "${GENESIS_ARGS[@]}"

  DEST="$REPO_DIR/res/genesis"
  mkdir -p "$DEST"
  cp out/genesis_*.mn "$DEST/"
  echo "Genesis files written to $DEST/"
  ls -lh "$DEST/genesis_"*"$NETWORK"*

# Generate chain-spec.json, chain-spec-raw.json, chain-spec-abridged.json for a network.
#
# Reads chainspec_id from res/cfg/<NETWORK>.toml as the source of truth. Derives
# the expected networkId via the same rule midnight-node uses internally and
# refuses to continue if the generated chainspec disagrees — guards against
# the silent state mismatch that midnightntwrk/midnight-node#1265 fixed at the
# node level.
generate-chain-spec NETWORK:
  #!/usr/bin/env bash
  set -euo pipefail

  NETWORK="{{NETWORK}}"
  REPO_DIR="{{justfile_directory()}}"

  NODE_OUT=$(nix build .#midnight-node --no-link --print-out-paths)
  NODE_BIN="$NODE_OUT/bin/midnight-node"
  echo "Using node: $NODE_BIN"

  TOML="$REPO_DIR/res/cfg/$NETWORK.toml"
  CHAINSPEC_ID=$(grep -E '^chainspec_id\s*=' "$TOML" | sed -E 's/.*=\s*"([^"]*)"/\1/')
  if [ -z "$CHAINSPEC_ID" ]; then
    echo "Error: chainspec_id not found in $TOML"
    exit 1
  fi

  if [ "$CHAINSPEC_ID" = "midnight" ]; then
    EXPECTED_NETWORK_ID="mainnet"
  else
    EXPECTED_NETWORK_ID="${CHAINSPEC_ID#midnight_}"
  fi

  echo "Network:             $NETWORK"
  echo "chainspec_id (TOML): $CHAINSPEC_ID"
  echo "Expected networkId:  $EXPECTED_NETWORK_ID"

  for f in "res/cfg/default.toml" "$TOML" "res/genesis/genesis_state_$NETWORK.mn" "res/genesis/genesis_block_$NETWORK.mn"; do
    if [ ! -f "$REPO_DIR/$f" ]; then
      echo "Error: required file not found: $REPO_DIR/$f"
      echo "Run 'just generate-genesis-state $NETWORK' first if genesis files are missing."
      exit 1
    fi
  done

  cd "$REPO_DIR"
  mkdir -p "res/$NETWORK"

  echo "Generating chain-spec..."
  CFG_PRESET="$NETWORK" "$NODE_BIN" build-spec --disable-default-bootnode > "res/$NETWORK/chain-spec.json"

  ACTUAL_NETWORK_ID=$(jq -r '.genesis.runtimeGenesis.config.midnight.networkId' "res/$NETWORK/chain-spec.json")
  ACTUAL_ID=$(jq -r '.id' "res/$NETWORK/chain-spec.json")
  echo "Generated chain-spec id=$ACTUAL_ID midnight.networkId=$ACTUAL_NETWORK_ID"
  if [ "$ACTUAL_NETWORK_ID" != "$EXPECTED_NETWORK_ID" ]; then
    echo "ERROR: chain-spec midnight.networkId '$ACTUAL_NETWORK_ID' != expected '$EXPECTED_NETWORK_ID'"
    echo "Check chainspec_id in $TOML — it should be 'midnight_$NETWORK' (or 'midnight' for mainnet)."
    exit 1
  fi

  echo "Creating abridged chain-spec..."
  jq '.genesis.runtimeGenesis.code = "<snipped>" | .properties.genesis_extrinsics = "<snipped>" | .properties.genesis_state = "<snipped>" | .genesis.runtimeGenesis.config.cNightObservation.config.observed_utxos = "<snipped>" | .genesis.runtimeGenesis.config.cNightObservation.config.mappings = "<snipped>" | .genesis.runtimeGenesis.config.cNightObservation.config.utxo_owners = "<snipped>"' \
    "res/$NETWORK/chain-spec.json" > "res/$NETWORK/chain-spec-abridged.json"

  echo "Generating raw chain-spec..."
  "$NODE_BIN" build-spec --chain="res/$NETWORK/chain-spec.json" --raw --disable-default-bootnode > "res/$NETWORK/chain-spec-raw.json"

  echo "Chain-spec files saved to res/$NETWORK/:"
  ls -lh "res/$NETWORK"/*.json

# Regenerate genesis state + chain-spec for one network in sequence.
rebuild-network NETWORK FUND_FAUCET_WALLETS="true":
  just generate-genesis-state {{NETWORK}} {{FUND_FAUCET_WALLETS}}
  just generate-chain-spec {{NETWORK}}

# Rebuild every regeneratable network.
rebuild-all:
  #!/usr/bin/env bash
  set -euo pipefail
  for n in {{rebuildable_networks}}; do
    echo "===== Rebuilding $n ====="
    just rebuild-network "$n"
  done

# ----- OCI image push (replaces Earthfile +node-image / +toolkit-image) -----

# Build + push the node OCI image to a registry path. Requires existing docker
# login or NIX_OCI_USER/NIX_OCI_PASS env vars (handled by the underlying skopeo).
push-node-oci REGISTRY_TAG:
  nix run .#midnight-node-oci.copyToRegistry -- docker://{{REGISTRY_TAG}}

push-toolkit-oci REGISTRY_TAG:
  nix run .#midnight-node-toolkit-oci.copyToRegistry -- docker://{{REGISTRY_TAG}}

# Load the OCI image into the local Docker daemon so it can be tagged/pushed
# the conventional way.
load-node-oci:
  nix run .#midnight-node-oci.copyToDockerDaemon

load-toolkit-oci:
  nix run .#midnight-node-toolkit-oci.copyToDockerDaemon

# ----- code quality -----

lint:
  cargo fmt --all -- --check
  cargo clippy --all-targets --all-features -- -D warnings

fmt:
  cargo fmt --all

test:
  cargo test --all-targets

check:
  cargo check --all-targets --all-features

# ----- existing E2E test recipes (unchanged) -----

toolkit-update-ledger-parameters-e2e NODE_IMAGE TOOLKIT_IMAGE:
  @scripts/tests/toolkit-update-ledger-parameters-e2e.sh {{NODE_IMAGE}} {{TOOLKIT_IMAGE}}
  @echo "✅ Toolkit Update Ledger Parameters E2E test completed successfully."

toolkit-e2e NODE_IMAGE TOOLKIT_IMAGE:
  @scripts/tests/toolkit-e2e.sh {{NODE_IMAGE}} {{TOOLKIT_IMAGE}}
  @echo "✅ Toolkit E2E test completed successfully."

toolkit-maintenance-e2e NODE_IMAGE TOOLKIT_IMAGE:
  @scripts/tests/toolkit-maintenance-e2e.sh {{NODE_IMAGE}} {{TOOLKIT_IMAGE}}
  @echo "✅ Toolkit Maintenance E2E test completed successfully."

toolkit-contracts-e2e NODE_IMAGE TOOLKIT_IMAGE:
  @scripts/tests/toolkit-contracts-e2e.sh {{NODE_IMAGE}} {{TOOLKIT_IMAGE}}
  @echo "✅ Toolkit Contracts E2E test completed successfully."

toolkit-mint-e2e NODE_IMAGE TOOLKIT_IMAGE:
  @scripts/tests/toolkit-mint-e2e.sh {{NODE_IMAGE}} {{TOOLKIT_IMAGE}}
  @echo "✅ Toolkit Mint E2E test completed successfully."

toolkit-tokens-minter-e2e NODE_IMAGE="" TOOLKIT_IMAGE="":
  @scripts/tests/toolkit-tokens-minter-e2e.sh {{NODE_IMAGE}} {{TOOLKIT_IMAGE}}
  @echo "✅ Toolkit Tokens Minter E2E test completed successfully."

toolkit-multi-dest-e2e TOOLKIT_IMAGE:
  @scripts/tests/toolkit-multi-dest-e2e.sh {{TOOLKIT_IMAGE}}
  @echo "✅ Toolkit Multi-Destination URL E2E test completed successfully."

startup-dev-e2e NODE_IMAGE:
  @scripts/tests/startup-dev-e2e.sh {{NODE_IMAGE}}
  @echo "✅ Startup E2E test in dev mode completed successfully."

startup-qanet-e2e NODE_IMAGE:
  @scripts/tests/startup-qanet-e2e.sh {{NODE_IMAGE}}
  @echo "✅ Startup E2E test in qanet mode completed successfully."

genesis-wallets-undeployed-e2e NODE_IMAGE TOOLKIT_IMAGE:
  @scripts/tests/genesis-wallets-undeployed-e2e.sh {{NODE_IMAGE}} {{TOOLKIT_IMAGE}}
  @echo "✅ Genesis wallet E2E test in undeployed network completed successfully."

genesis-wallets-devnet-e2e NODE_IMAGE TOOLKIT_IMAGE:
  @scripts/tests/genesis-wallets-devnet-e2e.sh {{NODE_IMAGE}} {{TOOLKIT_IMAGE}}
  @echo "✅ Genesis wallet E2E test in devnet network completed successfully."

indexer-api-e2e:
  @scripts/tests/indexer-api-e2e.sh
  @echo "✅ Indexer GraphQL API E2E test completed successfully."
