# Midnight Node build using crate2nix
# Produces per-crate granular builds with WASM runtime cross-compilation.
# Cargo.nix is generated automatically via IFD — no cargo binary or network access needed.
# Git dependencies are fetched at eval time via builtins.fetchGit.
#
# Ported from midnight-performance:perSystem/packages/node.nix. The source is
# this repo (`inputs.self`) instead of an external flake input.
{inputs, ...}: let
  mkMidnightNode = {pkgs, system, src, name ? "midnight-node"}: let
    inherit (pkgs) lib;
    gitRevision = src.shortRev or src.dirtyShortRev or "dev";
    rustToolchain = pkgs.rust-bin.fromRustupToolchainFile "${src}/rust-toolchain.toml";

    # --- Git dependency discovery (eval time) ---
    cargoLock = builtins.fromTOML (builtins.readFile "${src}/Cargo.lock");

    gitSources = let
      allSources = builtins.map (p: p.source or null) cargoLock.package;
      gitOnly = builtins.filter (s: s != null && lib.hasPrefix "git+" s) allSources;
      unique = lib.unique gitOnly;
      parseGitSource = source: let
        withoutGitPlus = lib.removePrefix "git+" source;
        parts = lib.splitString "#" withoutGitPlus;
        urlWithQuery = builtins.elemAt parts 0;
        commit = builtins.elemAt parts 1;
        baseUrl = builtins.elemAt (lib.splitString "?" urlWithQuery) 0;
      in {
        inherit commit baseUrl;
        fetched = builtins.fetchGit { url = baseUrl; rev = commit; allRefs = true; };
      };
    in builtins.listToAttrs (builtins.map (s: {
      name = s; value = parseGitSource s;
    }) unique);

    gitSourceFlags = builtins.map (source: let
      info = gitSources.${source};
    in ''--git-source "${info.baseUrl}#${info.commit}=${info.fetched}"'')
    (builtins.attrNames gitSources);

    # --- Crate hashes for git deps ---
    gitCrateHashes = pkgs.runCommand "git-crate-hashes.json" {
      nativeBuildInputs = [pkgs.nix pkgs.jq];
    } (let
      sourcesByPath = builtins.groupBy
        (e: builtins.unsafeDiscardStringContext e.storePath)
        (builtins.concatMap (source: let
          info = gitSources.${source};
          matchingPkgs = builtins.filter (p: (p.source or null) == source) cargoLock.package;
        in builtins.map (p: {
          storePath = toString info.fetched;
          sriBase64 = lib.removePrefix "sha256-" info.fetched.narHash;
          pkgId = "${p.name} ${p.version} (${source})";
        }) matchingPkgs) (builtins.attrNames gitSources));
    in ''
      _json='{}'
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (_: entries: let
        inherit (builtins.head entries) sriBase64;
      in ''
        _hex=$(echo ${builtins.toJSON sriBase64} | base64 -d | od -An -tx1 | tr -d ' \n')
        _hash=$(nix-hash --to-base32 --type sha256 "$_hex")
        ${lib.concatMapStringsSep "\n" (e: ''
          _json=$(echo "$_json" | jq --arg k ${builtins.toJSON e.pkgId} --arg v "$_hash" '. + {($k): $v}')
        '') entries}
      '') sourcesByPath)}
      echo "$_json" | jq . > $out
    '');

    # --- Crates.io manifests ---
    registryPkgs = builtins.filter (p:
      let s = p.source or null;
      in s != null && lib.hasPrefix "registry+" s && p ? checksum
    ) cargoLock.package;

    cratesIoManifests = pkgs.runCommand "crates-io-manifests" {
      nativeBuildInputs = [pkgs.gnutar];
    } ''
      mkdir -p $out
      ${lib.concatMapStringsSep "\n" (p: let
        tarball = pkgs.fetchurl {
          url = "https://static.crates.io/crates/${p.name}/${p.name}-${p.version}.crate";
          sha256 = p.checksum;
        };
      in ''
        mkdir -p $out/${p.name}/${p.version}
        tar xzf ${tarball} -C $out/${p.name}/${p.version} --strip-components=1 \
          ${p.name}-${p.version}/Cargo.toml 2>/dev/null || true
      '') registryPkgs}
    '';

    # --- Cargo.nix generation (IFD) ---
    cargoMetadataOnly = lib.cleanSourceWith {
      name = "cargo-metadata-only";
      inherit src;
      filter = path: type:
        type == "directory" ||
        builtins.baseNameOf path == "Cargo.toml" ||
        builtins.baseNameOf path == "Cargo.lock";
    };

    generatedCargoNix = pkgs.stdenvNoCC.mkDerivation {
      name = "generate-cargo-nix";
      src = cargoMetadataOnly;
      nativeBuildInputs = [inputs.crate2nix.packages.${system}.default];
      buildPhase = ''
        cp ${gitCrateHashes} $TMPDIR/crate-hashes.json
        chmod u+w $TMPDIR/crate-hashes.json
        mkdir -p nix
        crate2nix generate \
          --from-lockfile $src/Cargo.lock \
          -f $src/Cargo.toml \
          -o nix/Cargo.nix \
          -h $TMPDIR/crate-hashes.json \
          --crates-io-manifests ${cratesIoManifests} \
          ${lib.concatStringsSep " \\\n          " gitSourceFlags}
      '';
      installPhase = "cp nix/Cargo.nix $out";
    };

    # --- Patched source (place Cargo.nix + apply patches) ---
    patchedSrc = pkgs.runCommand "${name}-patched" {} ''
      cp -r ${src} $out
      chmod -R u+w $out
      cd $out
      patch -p1 < ${./node/179-docs.patch}
      patch -p1 < ${./node/cli-version.patch}
      patch -p1 < ${./node/toolkit-version.patch}
      mkdir -p $out/nix
      cp ${generatedCargoNix} $out/nix/Cargo.nix
    '';

    # --- Build infrastructure ---
    patchedBuildRustCrate = pkgs.callPackage inputs.build-rust-crate {
      rustc = rustToolchain;
      cargo = rustToolchain;
      defaultCodegenUnits = 16;
    };

    # Content-addressed isolated files for crate overrides
    workspaceCargoToml = builtins.toFile "workspace-Cargo.toml"
      (builtins.readFile (src + "/Cargo.toml"));
    nodeCargoToml = builtins.toFile "node-Cargo.toml"
      (builtins.readFile (src + "/node/Cargo.toml"));
    compactcVersion = builtins.toFile "COMPACTC_VERSION"
      (builtins.readFile (src + "/COMPACTC_VERSION"));
    sqlxDir = builtins.path { path = src + "/.sqlx"; name = "sqlx-queries"; };

    binaryen116 = pkgs.fetchFromGitHub {
      owner = "WebAssembly"; repo = "binaryen"; rev = "version_116";
      hash = "sha256-gMwbWiP+YDCVafQMBWhTuJGWmkYtnhEdn/oofKaUT08=";
    };

    # --- Crate overrides ---
    nodeOverrides = pkgs.defaultCrateOverrides // {
      midnight-storage-macros = _: {
        postUnpack = ''
          TOML=$(find . -path '*/storage-macros/Cargo.toml' | head -1)
          if [ -n "$TOML" ]; then
            sed -i 's/license.workspace = true/license = "Apache-2.0"/' "$TOML"
            sed -i 's/edition.workspace = true/edition = "2024"/' "$TOML"
            sed -i 's/version.workspace = true/version = "1.0.0"/' "$TOML"
            sed -i '/^resolver/d' "$TOML"
            echo '[workspace]' >> "$TOML"
          fi
        '';
      };
      midnight-node-ledger-helpers = _: {
        preConfigure = ''
          cp ${workspaceCargoToml} ./workspace-Cargo.toml
          substituteInPlace src/utils.rs \
            --replace-fail 'include_str!("../../../Cargo.toml")' 'include_str!("../workspace-Cargo.toml")'
        '';
      };
      midnight-node-ledger = _: {
        preConfigure = ''
          cp ${workspaceCargoToml} ./workspace-Cargo.toml
          substituteInPlace src/utils.rs \
            --replace-fail 'include_str!("../../Cargo.toml")' 'include_str!("../workspace-Cargo.toml")'
        '';
      };
      midnight-primitives-mainchain-follower = _: {
        SQLX_OFFLINE = "true";
        preConfigure = ''if [ -d ${sqlxDir} ]; then cp -r ${sqlxDir} .sqlx; fi'';
      };
      db-sync-sqlx = _: {
        SQLX_OFFLINE = "true";
        preConfigure = ''if [ -d ${sqlxDir} ]; then cp -r ${sqlxDir} .sqlx; fi'';
      };
      partner-chains-db-sync-data-sources = _: {
        SQLX_OFFLINE = "true";
        preConfigure = ''if [ -d ${sqlxDir} ]; then cp -r ${sqlxDir} .sqlx; fi'';
      };
      midnight-node-toolkit = _: {
        SUBSTRATE_CLI_GIT_COMMIT_HASH = gitRevision;
        preConfigure = ''
          cp ${nodeCargoToml} ./node-Cargo.toml
          cp ${compactcVersion} ./COMPACTC_VERSION
          substituteInPlace src/cli.rs \
            --replace-fail 'include_str!("../../../COMPACTC_VERSION")' 'include_str!("../COMPACTC_VERSION")'
          substituteInPlace src/cli.rs \
            --replace-fail '"../../../node/Cargo.toml"' '"../node-Cargo.toml"'
        '';
      };
      midnight-node = _: { SUBSTRATE_CLI_GIT_COMMIT_HASH = gitRevision; };
      midnight-node-runtime = _: {
        WASM_BINARY_PATH = "${wasmRuntime}/midnight_node_runtime.compact.wasm";
        nativeBuildInputs = [pkgs.pkg-config pkgs.zlib pkgs.libclang];
      };
      frame-storage-access-test-runtime = _: {
        SKIP_FRAME_STORAGE_ACCESS_TEST_RUNTIME_WASM_BUILD = "1";
      };
      substrate-wasm-builder = attrs: {
        patches = (attrs.patches or []) ++ [./node/substrate-wasm-builder-prebuilt.patch];
      };
      prost-build = _: {
        nativeBuildInputs = [pkgs.protobuf];
        PROTOC = "${pkgs.protobuf}/bin/protoc";
      };
      litep2p = _: { buildInputs = [pkgs.protobuf]; };
      sc-network = _: { buildInputs = [pkgs.protobuf]; };
      sc-network-light = _: { buildInputs = [pkgs.protobuf]; };
      sc-network-sync = _: { buildInputs = [pkgs.protobuf]; };
      sc-authority-discovery = _: {
        buildInputs = [pkgs.protobuf];
        PROTOC = "${pkgs.protobuf}/bin/protoc";
      };
      openssl-sys = _: {
        nativeBuildInputs = [pkgs.pkg-config];
        buildInputs = [pkgs.openssl];
        OPENSSL_NO_VENDOR = "1";
        OPENSSL_DIR = "${pkgs.openssl.dev}";
        OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";
        OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
      };
      ring = _: { nativeBuildInputs = [pkgs.llvmPackages.clang]; };
      wasm-opt-sys = _: {
        nativeBuildInputs = [pkgs.pkg-config pkgs.cmake];
        buildInputs = [pkgs.binaryen pkgs.libclang.lib];
        LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
        CRATE_CC_NO_DEFAULTS = "1";
        dontCheckForBrokenSymlinks = true;
        postFixup = ''find $out -xtype l -delete || true'';
      };
      wasm-opt-cxx-sys = _: {
        LIBCLANG_PATH = "${pkgs.clang.cc.lib}/lib";
        CRATE_CC_NO_DEFAULTS = "1";
        patchPhase = ''cp -r ${binaryen116} binaryen'';
        CXXFLAGS = "-I${binaryen116}/src -I${binaryen116}/src/tools";
        nativeBuildInputs = [pkgs.clang pkgs.llvm pkgs.pkg-config];
        dontCheckForBrokenSymlinks = true;
      };
      librocksdb-sys = _: {
        nativeBuildInputs = [pkgs.pkg-config pkgs.llvmPackages.clang-unwrapped.lib];
        buildInputs = [pkgs.rocksdb pkgs.pkg-config];
        ROCKSDB_LIB_DIR = "${pkgs.rocksdb}/lib/";
        LIBCLANG_PATH = "${pkgs.clang.cc.lib}/lib";
        C_INCLUDE_PATH = "${pkgs.clang.cc.lib}/lib/clang/19/include";
        BINDGEN_EXTRA_CLANG_ARGS = "-I${pkgs.glibc.dev}/include -I${pkgs.clang.cc.lib}/lib/clang/19/include";
      };
      proc-macro-crate = attrs: attrs // {
        patches = []; prePatch = ""; postPatch = ""; doCheck = false;
      };
    };

    # --- Native Cargo.nix import ---
    cargoNix = import "${patchedSrc}/nix/Cargo.nix" {
      inherit pkgs;
      buildRustCrateForPkgs = _: patchedBuildRustCrate;
      defaultCrateOverrides = nodeOverrides;
    };

    # --- WASM cross-compilation ---
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

    wasmStdenv = pkgs.stdenvNoCC // { hostPlatform = wasmHostPlatform; hasCC = false; };

    wasmCrateOverrides = pkgs.defaultCrateOverrides // {
      midnight-node-runtime = _: { type = ["cdylib"]; SKIP_WASM_BUILD = "1"; };
      proc-macro-crate = attrs: attrs // { patches = []; prePatch = ""; postPatch = ""; doCheck = false; };
    };

    wasmBuildRustCrateInner = pkgs.callPackage inputs.build-rust-crate {
      stdenv = wasmStdenv;
      rustc = rustToolchain;
      cargo = rustToolchain;
      defaultCodegenUnits = 1;
      defaultCrateOverrides = wasmCrateOverrides;
    };

    wasmBuildRustCrate = crate: wasmBuildRustCrateInner (crate // {
      extraRustcOpts = (crate.extraRustcOpts or []) ++ ["--cfg" "substrate_runtime"];
    });

    wasmPkgs = pkgs // { stdenv = wasmStdenv; defaultCrateOverrides = wasmCrateOverrides; };

    wasmCargoNix = import "${patchedSrc}/nix/Cargo.nix" {
      pkgs = wasmPkgs;
      rootFeatures = [];
      extraTargetFlags = { env = ""; };
      stripFeatures = ["std" "use_std" "proc-macro" "proc_support"];
      hostPlatformCrates = [
        "proc-macro2" "syn" "quote" "prettyplease" "rustc_version" "semver"
        "macro_magic_core" "synstructure" "darling_core" "derive_builder_core"
        "serde_derive_internals" "frame-support-procedural-tools" "scale-typegen"
        "polkavm-derive-impl" "expander"
        "proc-macro2-diagnostics" "proc-macro-error" "proc-macro-error2" "proc-macro-warning"
        "secp256k1-sys" "secp256k1"
      ];
      buildRustCrateForPkgs = pkgs':
        if pkgs'.stdenv.hostPlatform.isWasm or false
        then wasmBuildRustCrate
        else patchedBuildRustCrate;
    };

    wasmRuntimeRaw = wasmCargoNix.workspaceMembers."midnight-node-runtime".build;

    wasmRuntime = pkgs.runCommand "midnight-runtime-wasm" {
      nativeBuildInputs = [pkgs.binaryen];
    } ''
      mkdir -p $out
      wasm-opt -O0 --strip-dwarf --signext-lowering \
        ${wasmRuntimeRaw.lib}/lib/*midnight_node_runtime*.wasm \
        -o $out/midnight_node_runtime.compact.wasm
    '';

  in {
    midnight-node = cargoNix.workspaceMembers.midnight-node.build;
    midnight-node-toolkit = cargoNix.workspaceMembers.midnight-node-toolkit.build;
    inherit wasmRuntime;
  };

in {
  perSystem = {pkgs, system, ...}: let
    build = mkMidnightNode {
      inherit pkgs system;
      src = inputs.self;
    };
  in {
    packages = {
      inherit (build) midnight-node midnight-node-toolkit wasmRuntime;
    };
  };
}
