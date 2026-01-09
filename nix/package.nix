{
  inputs,
  pkgs,
  targetSystem
}: let
  inherit (pkgs) lib;

  # use rust-toolchain as a basis
  # wasm32v1-none renders compiling std from source irrelevant
  rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ../rust-toolchain.toml;

  craneLib = (inputs.crane.mkLib pkgs).overrideToolchain rustToolchain;

  src = lib.cleanSourceWith {
    src = lib.cleanSource ../.;
    filter = path: type:
      craneLib.filterCargoSources path type
      || lib.hasSuffix ".scale" path
      || lib.hasSuffix ".mn" path
      || lib.hasSuffix ".json" path
      || lib.hasSuffix "COMPACTC_VERSION" path;
    name = "source";
  };

  packageName = craneLib.crateNameFromCargoToml {cargoToml = builtins.path {path = src + "/node/Cargo.toml";};};

  commonArgs =
    {
      inherit (packageName) version pname;
      inherit src;
      strictDeps = true;

      nativeBuildInputs =
        [
          pkgs.gnum4
          pkgs.protobuf
        ]
        ++ lib.optionals pkgs.stdenv.isLinux [
          pkgs.pkg-config
          pkgs.llvmPackages.lld
          pkgs.stdenv.cc.cc.lib
        ];
      buildInputs =
        lib.optionals pkgs.stdenv.isLinux [
          pkgs.openssl
        ]
        ++ lib.optionals pkgs.stdenv.isDarwin [
          pkgs.libiconv
          pkgs.darwin.apple_sdk_12_3.frameworks.SystemConfiguration
          pkgs.darwin.apple_sdk_12_3.frameworks.Security
          pkgs.darwin.apple_sdk_12_3.frameworks.CoreFoundation
        ];
    }
    // lib.optionalAttrs pkgs.stdenv.isLinux {
      # Use lld for faster linking and better handling of large projects
        RUSTFLAGS = "-Clink-arg=-fuse-ld=lld";
      # The Wasm linker for wasm32v1-none target:
        CARGO_TARGET_WASM32V1_NONE_LINKER = "${pkgs.llvmPackages.lld}/bin/wasm-ld";
        # Required for substrate-wasm-builder to find libstdc++
        LD_LIBRARY_PATH = "${pkgs.stdenv.cc.cc.lib}/lib";
        # Skip WASM build for polkadot-sdk test runtime (has broken path deps to cumulus when vendored)
        # See: https://paritytech.github.io/polkadot-sdk/master/substrate_wasm_builder/index.html
        SKIP_FRAME_STORAGE_ACCESS_TEST_RUNTIME_WASM_BUILD = "1";
    }
    // lib.optionalAttrs pkgs.stdenv.isDarwin {
      # for bindgen, used by libproc, used by metrics_process
      LIBCLANG_PATH = "${lib.getLib pkgs.llvmPackages.libclang}/lib";
      CRATE_CC_NO_DEFAULTS = "1";
    };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  package = craneLib.buildPackage (commonArgs
    // {
      inherit cargoArtifacts;
      doCheck = false; # we run tests elsewhere
    });
in
  package
