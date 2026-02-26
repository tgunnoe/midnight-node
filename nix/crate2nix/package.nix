# Midnight Node build using crate2nix
# Provides incremental builds where each crate is a separate derivation
#
# Usage from flake.nix:
#   packages.midnight-node-crate2nix = import ./nix/crate2nix/package.nix {
#     inherit pkgs lib;
#     rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
#     src = ./.;
#   };
#
# To regenerate Cargo.nix after Cargo.lock changes:
#   nix run github:nix-community/crate2nix -- generate -o nix/crate2nix/Cargo.nix
#
# To regenerate cargo-metadata.json:
#   cargo metadata --format-version 1 > nix/crate2nix/cargo-metadata.json

{ pkgs
, rustToolchain
, src  # The midnight-node source root
}:

let
  lib = pkgs.lib;
  # Define cargo path for use in overrides (needed by proc-macro-crate)
  cargo = "${rustToolchain}/bin/cargo";

  # Isolated store paths for files referenced in crate overrides — prevents
  # the full repo hash from leaking into crate derivations.
  workspaceCargoToml = builtins.path {
    path = src + "/Cargo.toml";
    name = "workspace-Cargo.toml";
  };
  sqlxDir = builtins.path {
    path = src + "/.sqlx";
    name = "sqlx-queries";
  };

  # Custom buildRustCrate with patched mkRustcDepArgs for packageId-based lookups.
  # This handles the case where two crates have the same name and version but
  # come from different git sources (e.g., mn-ledger vs mn-ledger-hf).
  patchedBuildRustCrate = pkgs.callPackage ../build-rust-crate {
    rustc = rustToolchain;
    cargo = rustToolchain;
    defaultCodegenUnits = 16;
  };

  # Path to pre-generated cargo metadata JSON for offline WASM builds
  cargoMetadataPath = ./cargo-metadata.json;

  # Import Cargo.nix directly — relative paths (../../node, etc.) resolve
  # correctly relative to Cargo.nix's location, and lib.cleanSourceWith
  # creates separate store paths per crate directory automatically,
  # giving us per-crate rebuild granularity.
  cargoNix = import ./Cargo.nix {
    inherit pkgs;
    # Override the default crate builder with our patched version
    buildRustCrateForPkgs = pkgs': patchedBuildRustCrate;

    defaultCrateOverrides = pkgs.defaultCrateOverrides // {
      # midnight-node-ledger-helpers uses include_str!("../../../Cargo.toml")
      # but crate2nix builds each crate in isolation. Patch the source to use a file we provide.
      midnight-node-ledger-helpers = attrs: {
        preConfigure = ''
          cp ${workspaceCargoToml} ./workspace-Cargo.toml
          substituteInPlace src/utils.rs \
            --replace-fail 'include_str!("../../../Cargo.toml")' 'include_str!("../workspace-Cargo.toml")'
        '';
      };

      # midnight-node-ledger uses include_str!("../../Cargo.toml")
      midnight-node-ledger = attrs: {
        preConfigure = ''
          cp ${workspaceCargoToml} ./workspace-Cargo.toml
          substituteInPlace src/utils.rs \
            --replace-fail 'include_str!("../../Cargo.toml")' 'include_str!("../workspace-Cargo.toml")'
        '';
      };

      # sqlx crates need SQLX_OFFLINE=true to skip compile-time query verification
      midnight-primitives-mainchain-follower = attrs: {
        SQLX_OFFLINE = "true";
        preConfigure = ''
          if [ -d ${sqlxDir} ]; then
            cp -r ${sqlxDir} .sqlx
          fi
        '';
      };
      db-sync-sqlx = attrs: {
        SQLX_OFFLINE = "true";
        preConfigure = ''
          if [ -d ${sqlxDir} ]; then
            cp -r ${sqlxDir} .sqlx
          fi
        '';
      };
      partner-chains-db-sync-data-sources = attrs: {
        SQLX_OFFLINE = "true";
        preConfigure = ''
          if [ -d ${sqlxDir} ]; then
            cp -r ${sqlxDir} .sqlx
          fi
        '';
      };

      # Skip building frame-storage-access-test-runtime WASM
      frame-storage-access-test-runtime = attrs: {
        SKIP_FRAME_STORAGE_ACCESS_TEST_RUNTIME_WASM_BUILD = "1";
      };

      # Override for the runtime crate
      # Instead of trying to make substrate-wasm-builder work in the Nix sandbox,
      # we skip it entirely. The build.rs will generate a dummy wasm_binary.rs
      # when SKIP_WASM_BUILD is set.
      midnight-node-runtime = attrs: {
        # Skip substrate-wasm-builder - the build.rs checks this and generates dummy WASM
        SKIP_WASM_BUILD = "1";
        nativeBuildInputs = with pkgs; [
          pkg-config
          zlib
          libclang
        ];
      };

      # Keep the patch for substrate-wasm-builder disabled for now since
      # SKIP_WASM_BUILD=1 means the patched code path won't run, and the patch
      # adds serde_json usage without the corresponding dependency.
      # substrate-wasm-builder = attrs: {
      #   patches = (attrs.patches or []) ++ [ ./substrate-wasm-builder-offline.patch ];
      # };

      # Override for crates that need protobuf
      prost-build = attrs: {
        nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [ pkgs.protobuf ];
        PROTOC = "${pkgs.protobuf}/bin/protoc";
      };

      litep2p = attrs: {
        buildInputs = (attrs.buildInputs or []) ++ [ pkgs.protobuf ];
      };

      sc-network = attrs: {
        buildInputs = (attrs.buildInputs or []) ++ [ pkgs.protobuf ];
      };

      sc-network-light = attrs: {
        buildInputs = (attrs.buildInputs or []) ++ [ pkgs.protobuf ];
      };

      sc-network-sync = attrs: {
        buildInputs = (attrs.buildInputs or []) ++ [ pkgs.protobuf ];
      };

      # Override for crates that need openssl
      openssl-sys = attrs: {
        nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [ pkgs.pkg-config ];
        buildInputs = (attrs.buildInputs or []) ++ [ pkgs.openssl ];
        OPENSSL_NO_VENDOR = "1";
        OPENSSL_DIR = "${pkgs.openssl.dev}";
        OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";
        OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
      };

      # Override for ring (needs clang for asm)
      ring = attrs: {
        nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [ pkgs.llvmPackages.clang ];
      };

      # Override wasm-opt-sys
      wasm-opt-sys = attrs: {
        nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [ pkgs.pkg-config pkgs.cmake ];
        buildInputs = (attrs.buildInputs or []) ++ [ pkgs.binaryen pkgs.libclang.lib ];
        LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
        dontCheckForBrokenSymlinks = true;
        postFixup = ''
          find $out -xtype l -delete || true
        '';
      };

      # wasm-opt-cxx-sys
      wasm-opt-cxx-sys = let
        binaryen116 = pkgs.fetchFromGitHub {
          owner = "WebAssembly";
          repo = "binaryen";
          rev = "version_116";
          hash = "sha256-gMwbWiP+YDCVafQMBWhTuJGWmkYtnhEdn/oofKaUT08=";
        };
      in attrs: {
        LIBCLANG_PATH = "${pkgs.clang.cc.lib}/lib";
        patchPhase = ''
          cp -r ${binaryen116} binaryen
        '';
        CXXFLAGS = "-I${binaryen116}/src -I${binaryen116}/src/tools";
        nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [ pkgs.clang pkgs.llvm pkgs.pkg-config ];
        dontCheckForBrokenSymlinks = true;
      };

      # Override rocksdb
      librocksdb-sys = attrs: {
        nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [
          pkgs.pkg-config
          pkgs.llvmPackages.clang-unwrapped.lib
        ];
        buildInputs = (attrs.buildInputs or []) ++ [ pkgs.rocksdb pkgs.pkg-config ];
        ROCKSDB_LIB_DIR = "${pkgs.rocksdb}/lib/";
        LIBCLANG_PATH = "${pkgs.clang.cc.lib}/lib";
        C_INCLUDE_PATH = "${pkgs.clang.cc.lib}/lib/clang/19/include";
        BINDGEN_EXTRA_CLANG_ARGS = "-I${pkgs.glibc.dev}/include -I${pkgs.clang.cc.lib}/lib/clang/19/include";
      };

      # Override proc-macro-crate to bypass problematic nixpkgs patches
      proc-macro-crate = attrs: attrs // {
        patches = [];
        prePatch = "";
        postPatch = "";
        doCheck = false;
      };

    };
  };

in {
  # Main midnight-node binary
  midnight-node = cargoNix.workspaceMembers.midnight-node.build;

  # Toolkit utility
  midnight-node-toolkit = cargoNix.workspaceMembers.midnight-node-toolkit.build;

  # Expose cargoNix for debugging
  inherit cargoNix;
}
