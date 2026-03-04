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

  # ---------------------------------------------------------------------------
  # WASM cross-compilation: build the runtime as wasm32v1-none cdylib
  # ---------------------------------------------------------------------------

  # Elaborate the WASM host platform for wasm32v1-none (MVP-only, no std).
  wasmHostPlatform = let
    base = lib.systems.elaborate { config = "wasm32-unknown-none"; };
  in base // {
    linker = "lld";
    rust = base.rust // {
      rustcTarget = "wasm32v1-none";
      rustcTargetSpec = "wasm32v1-none";
      platform = base.rust.platform // { os = "none"; };
    };
  };

  # Cross-compilation stdenv for wasm32v1-none.
  # We extend stdenvNoCC (no C compiler needed for pure Rust) with the
  # WASM host platform. The buildPlatform stays as the native system
  # so that build scripts and proc-macros compile and run natively.
  wasmStdenv = pkgs.stdenvNoCC // {
    hostPlatform = wasmHostPlatform;
    hasCC = false;
  };

  # WASM crate overrides — baked into wasmBuildRustCrate so that
  # Cargo.nix's defaultCrateOverrides matches pkgs.defaultCrateOverrides
  # (bypassing the .override call which doesn't work with our wrapper).
  wasmCrateOverrides = pkgs.defaultCrateOverrides // {
    # Override crate type to cdylib for .wasm output
    midnight-node-runtime = attrs: {
      type = [ "cdylib" ];
      SKIP_WASM_BUILD = "1";
    };

    # Bypass problematic nixpkgs patches for proc-macro-crate
    proc-macro-crate = attrs: attrs // {
      patches = [];
      prePatch = "";
      postPatch = "";
      doCheck = false;
    };
  };

  # buildRustCrate configured for wasm32v1-none output.
  # Uses wasmStdenv so build-crate.nix adds --target wasm32v1-none to rustc
  # and configure-crate.nix sets correct CARGO_CFG_TARGET_* env vars.
  # Crate overrides are baked in here (not in Cargo.nix) to avoid the
  # .override compatibility issue with our std-stripping wrapper.
  wasmBuildRustCrateInner = pkgs.callPackage ../build-rust-crate {
    stdenv = wasmStdenv;
    rustc = rustToolchain;
    cargo = rustToolchain;
    defaultCodegenUnits = 1;
    defaultCrateOverrides = wasmCrateOverrides;
  };

  # WASM crate builder: adds substrate_runtime cfg for runtime_interface
  # WASM stub generation. Feature stripping (std, use_std, proc-macro, etc.)
  # is handled by Cargo.nix's stripFeatures parameter BEFORE dependency
  # resolution, so optional deps gated on these features are not activated.
  wasmBuildRustCrate = crate: wasmBuildRustCrateInner (crate // {
    extraRustcOpts = (crate.extraRustcOpts or []) ++ [
      "--cfg" "substrate_runtime"
    ];
  });

  # Wrap native pkgs with WASM stdenv and overrides for Cargo.nix import.
  # pkgs.buildPackages still points to native pkgs (since the base pkgs
  # is non-cross), so proc-macros and build scripts compile natively.
  # Setting defaultCrateOverrides to wasmCrateOverrides ensures the
  # equality check in Cargo.nix (crateOverrides == pkgs.defaultCrateOverrides)
  # is TRUE, which bypasses .override (incompatible with our std-stripping wrapper).
  wasmPkgs = pkgs // {
    stdenv = wasmStdenv;
    defaultCrateOverrides = wasmCrateOverrides;
  };

  # Same Cargo.nix but targeting wasm — no default features (no_std).
  # stripFeatures removes std-related features BEFORE dependency resolution,
  # so optional deps gated on these features (like syn in macro_magic's
  # proc_support) are not activated for the WASM build.
  # hostPlatformCrates routes remaining proc-macro helpers that unconditionally
  # need std to the build platform.
  wasmCargoNix = import ./Cargo.nix {
    pkgs = wasmPkgs;
    rootFeatures = [];  # no default, no std
    extraTargetFlags = { env = ""; };
    stripFeatures = [
      "std" "use_std" "proc-macro"
      # Substrate/ecosystem features that gate proc-macro infrastructure
      "proc_support"
    ];
    hostPlatformCrates = [
      # These crates unconditionally require std and are only ever used
      # by proc-macros / build scripts — never at WASM runtime.
      "proc-macro2" "syn" "quote" "prettyplease"
      "rustc_version" "semver"
      # Proc-macro support crates that need std/proc-macro2
      "macro_magic_core" "synstructure"
      "darling_core" "derive_builder_core" "serde_derive_internals"
      "frame-support-procedural-tools" "scale-typegen"
      "polkavm-derive-impl" "expander"
      "proc-macro2-diagnostics" "proc-macro-error" "proc-macro-error2" "proc-macro-warning"
    ];
    buildRustCrateForPkgs = pkgs':
      if pkgs'.stdenv.hostPlatform.isWasm or false
      then wasmBuildRustCrate
      else patchedBuildRustCrate;
  };

  # Raw WASM runtime derivation — per-crate cached via crate2nix
  wasmRuntimeRaw = wasmCargoNix.workspaceMembers."midnight-node-runtime".build;

  # Compact the WASM blob with wasm-opt (runs on host platform)
  wasmRuntime = pkgs.runCommand "midnight-runtime-wasm" {
    nativeBuildInputs = [ pkgs.binaryen ];
  } ''
    mkdir -p $out
    wasm-opt -O0 \
      --strip-dwarf \
      --signext-lowering \
      ${wasmRuntimeRaw.lib}/lib/*midnight_node_runtime*.wasm \
      -o $out/midnight_node_runtime.compact.wasm
  '';

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

      # Inject the pre-built WASM binary instead of running nested cargo build.
      midnight-node-runtime = attrs: {
        WASM_BINARY_PATH = "${wasmRuntime}/midnight_node_runtime.compact.wasm";
        nativeBuildInputs = with pkgs; [
          pkg-config
          zlib
          libclang
        ];
      };

      # Patch substrate-wasm-builder to check WASM_BINARY_PATH before
      # attempting its own nested cargo build.
      substrate-wasm-builder = attrs: {
        patches = (attrs.patches or []) ++ [ ./substrate-wasm-builder-prebuilt.patch ];
      };

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
  # Main midnight-node binary (with embedded WASM runtime)
  midnight-node = cargoNix.workspaceMembers.midnight-node.build;

  # Toolkit utility
  midnight-node-toolkit = cargoNix.workspaceMembers.midnight-node-toolkit.build;

  # Pre-built WASM runtime blob
  inherit wasmRuntime;

  # Expose cargoNix for debugging
  inherit cargoNix;

  # Debug: expose wasmCargoNix for feature inspection
  inherit wasmCargoNix;
}
