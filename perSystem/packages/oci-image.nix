# OCI container images for midnight-node and midnight-node-toolkit, built
# via nix2container. Replaces images/{node,toolkit}/Dockerfile.
#
# vs the Earthfile/Dockerfile setup these replace:
#   - No amazonlinux base layer; uses a minimal nix-derived rootfs
#   - Content-addressed layers (massively faster pulls/pushes for repeat
#     builds — only changed crates produce new layers)
#   - No `microdnf install`; runtime utilities come from the same nixpkgs
#     pin everything else uses
#   - No bytehound binary fetched at build time (was an x86_64-only
#     no-op on arm64); install via nix overlay if/when needed
#
# Push to GHCR via:
#   nix run .#midnight-node-oci.copyToRegistry -- ghcr.io/midnightntwrk/midnight-node:tag
#   nix run .#midnight-node-toolkit-oci.copyToRegistry -- ghcr.io/midnightntwrk/midnight-node-toolkit:tag
{inputs, ...}: {
  perSystem = {
    pkgs,
    self',
    system,
    ...
  }: let
    n2c = inputs.nix2container.packages.${system}.nix2container;

    # Repo-relative paths we want baked into the image.
    src = inputs.self;
    gitRev = src.shortRev or src.dirtyShortRev or "dev";

    # Runtime utilities that the previous Dockerfile installed via microdnf.
    # Only the ones the entrypoints actually need at runtime, plus a few
    # operator conveniences (jq, tree, strace) so an exec into a running
    # container is debuggable.
    runtimeUtils = with pkgs; [
      bash
      coreutils # cp/mkdir/chown/etc — entrypoints depend on these
      cacert
      curl
      gnutar
      gzip
      jq
      tree
      procps
      strace
      gdb
      vim
      gnugrep
      gnused
      util-linux # runuser, used by toolkit entrypoint
    ];

    # res/ baked in. The Dockerfile copies the whole tree; we do the same so
    # CHAIN_SPEC env var paths like 'res/<network>/chain-spec-raw.json'
    # resolve at runtime without an external mount.
    resTree = pkgs.runCommand "midnight-node-res" {} ''
      mkdir -p $out
      cp -r ${src}/res $out/
      # Trim files that aren't useful at runtime to keep the layer small.
      # (Remove if these turn out to be needed for some network.)
      find $out/res -name '.gitkeep' -delete || true
    '';

    envrc = pkgs.runCommand "midnight-node-envrc" {} ''
      mkdir -p $out/bin
      cp ${src}/.envrc $out/bin/.envrc
    '';

    # ---------- node image ----------

    # Faithful port of node/bin/entrypoint.sh, but with a hardened shebang
    # (#!/usr/bin/env bash) — the original used /bin/bash which is fine
    # inside the previous amazonlinux base but won't be in our minimal
    # rootfs unless we explicitly link it.
    nodeEntrypoint = pkgs.writeShellApplication {
      name = "node-entrypoint";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        # Default base path from container ENV
        DEFAULT_BASE_PATH="''${BASE_PATH:-/node/chain}"

        # Parse arguments to find --base-path / --base-path=...
        PARSED_BASE_PATH=""
        prev_arg=""
        for arg in "$@"; do
          if [[ "$arg" == --base-path=* ]]; then
            PARSED_BASE_PATH="''${arg#*=}"
          elif [[ "$prev_arg" == "--base-path" ]]; then
            PARSED_BASE_PATH="$arg"
          fi
          prev_arg="$arg"
        done

        FINAL_BASE_PATH="''${PARSED_BASE_PATH:-$DEFAULT_BASE_PATH}"

        if [ ! -d "$FINAL_BASE_PATH" ]; then
          mkdir -p "$FINAL_BASE_PATH"
        fi

        exec ${self'.packages.midnight-node}/bin/midnight-node "$@"
      '';
    };

    midnight-node-oci = n2c.buildImage {
      name = "ghcr.io/midnightntwrk/midnight-node";
      tag = "${gitRev}";
      copyToRoot = [
        (pkgs.buildEnv {
          name = "midnight-node-rootfs";
          paths = runtimeUtils ++ [self'.packages.midnight-node nodeEntrypoint];
          pathsToLink = ["/bin" "/share" "/etc"];
        })
        resTree
        envrc
      ];
      config = {
        Entrypoint = ["${nodeEntrypoint}/bin/node-entrypoint"];
        ExposedPorts = {
          "30333/tcp" = {};
          "9933/tcp" = {};
          "9944/tcp" = {};
          "9615/tcp" = {};
        };
        Env = [
          "BASE_PATH=/node/chain"
          "RUST_BACKTRACE=1"
          "PATH=/bin"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        ];
        User = "10001:10001";
      };
    };

    # ---------- toolkit image ----------

    toolkitEntrypoint = pkgs.writeShellApplication {
      name = "toolkit-entrypoint";
      runtimeInputs = [pkgs.coreutils pkgs.util-linux];
      text = ''
        MOUNTED_DIRS=(/tmp /mnt/output /out)

        # Only mount cache directory when MN_FETCH_CACHE uses redb: prefix
        if [[ "''${MN_FETCH_CACHE:-}" == redb:* ]]; then
          FETCH_CACHE_PATH="''${MN_FETCH_CACHE#redb:}"
          FETCH_CACHE_DIR="$(dirname "$FETCH_CACHE_PATH")"
          MOUNTED_DIRS+=("$FETCH_CACHE_DIR")
        fi

        mkdir -p "''${MOUNTED_DIRS[@]}"

        # Note: the original Dockerfile-based image started as root and
        # chown'd the mount points to appuser before runuser-ing into the
        # binary. With nix2container we can't easily start as root and
        # drop privileges, so we run as appuser directly. If a mount needs
        # specific ownership, set it on the host or in the compose volume
        # spec.
        exec ${self'.packages.midnight-node-toolkit}/bin/midnight-node-toolkit "$@"
      '';
    };

    # The previous toolkit image embedded a small fixture under
    # /test-static/simple-merkle-tree pulled from static/contracts. Mirror
    # that conditionally — no-op if the source tree doesn't include it.
    toolkitTestStatic = pkgs.runCommand "toolkit-test-static" {} ''
      if [ -d ${src}/static/contracts/simple-merkle-tree ]; then
        mkdir -p $out/test-static
        cp -r ${src}/static/contracts/simple-merkle-tree $out/test-static/
      else
        mkdir -p $out
      fi
    '';

    midnight-node-toolkit-oci = n2c.buildImage {
      name = "ghcr.io/midnightntwrk/midnight-node-toolkit";
      tag = "${gitRev}";
      copyToRoot = [
        (pkgs.buildEnv {
          name = "midnight-node-toolkit-rootfs";
          paths = runtimeUtils ++ [self'.packages.midnight-node-toolkit toolkitEntrypoint];
          pathsToLink = ["/bin" "/share" "/etc"];
        })
        envrc
        toolkitTestStatic
      ];
      config = {
        Entrypoint = ["${toolkitEntrypoint}/bin/toolkit-entrypoint"];
        Env = [
          "TOOLKIT_JS_PATH=/toolkit-js"
          "MIDNIGHT_LEDGER_TEST_STATIC_DIR=/test-static"
          "MIDNIGHT_PP=/.cache/midnight/zk-params"
          "MN_FETCH_CACHE=redb:/.cache/toolkit_fetch_cache.db"
          "MN_LEDGER_CACHE_DB=/.cache/toolkit_ledger_cache_db"
          "PATH=/bin"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
        ];
        User = "10001:10001";
      };
    };
  in {
    packages = {
      inherit midnight-node-oci midnight-node-toolkit-oci;
    };
  };
}
