_: {
  perSystem = {
    pkgs,
    lib,
    system,
    ...
  }: let
    isDarwin = lib.hasSuffix "darwin" system;
    isDarwinAArch64 = system == "aarch64-darwin";

    # Pin the Rust toolchain from rust-toolchain.toml so the dev shell matches
    # what builds in CI.
    rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ../../rust-toolchain.toml;

    darwinPkgs = with pkgs.darwin; [
      libiconv
      apple_sdk.frameworks.SystemConfiguration
      apple_sdk.frameworks.Security
    ];
  in {
    devShells.default = pkgs.mkShell {
      packages =
        [rustToolchain]
        ++ (with pkgs; [
          clang
          pkg-config
          zlib
          protobuf
          rocksdb
          # Tools previously brought in by .envrc / Earthfile
          jq
          just
          git
        ])
        ++ lib.optionals isDarwin darwinPkgs;

      buildInputs = [pkgs.libclang];

      WASM_BUILD_STD = 0;
      LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
      PROTOC = "${pkgs.protobuf}/bin/protoc";
      ROCKSDB_LIB_DIR = "${pkgs.rocksdb}/lib";
      BINDGEN_EXTRA_CLANG_ARGS = lib.optionalString isDarwinAArch64 "-isystem ${pkgs.darwin.apple_sdk.Libsystem}/include";

      shellHook = ''
        # Source repo-local env (git hook setup, runtime config defaults).
        # Note: EARTHLY_CONFIG export is now a no-op since earthly is gone.
        if [ -f ./.envrc ]; then . ./.envrc; fi
      '';
    };
  };
}
