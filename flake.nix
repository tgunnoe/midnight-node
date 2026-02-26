{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.rust-overlay.overlays.default ];
      };
      isDarwin = pkgs.lib.hasSuffix "darwin" system;
      isDarwinAArch64 = system == "aarch64-darwin";
    
      # Load toolchain from rust-toolchain.toml
      rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

      # Import the crate2nix build
      crate2nixBuild = import ./nix/crate2nix/package.nix {
        inherit pkgs rustToolchain;
        src = ./.;
      };

    in {
      # Packages built with crate2nix (incremental builds)
      packages = {
        midnight-node = crate2nixBuild.midnight-node;
        midnight-node-toolkit = crate2nixBuild.midnight-node-toolkit;
        default = crate2nixBuild.midnight-node;
      };

      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
           earthly rustup clang pkg-config zlib
        ] ++ (if isDarwin
          then with pkgs.darwin; [ libiconv apple_sdk.frameworks.SystemConfiguration apple_sdk.frameworks.Security ]
          else []);
        buildInputs = [ pkgs.libclang ];
        WASM_BUILD_STD=0;
        LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
        PROTOC = "${pkgs.protobuf}/bin/protoc";
        ROCKSDB_LIB_DIR = "${pkgs.rocksdb}/lib";
        BINDGEN_EXTRA_CLANG_ARGS = with pkgs;
          if isDarwinAArch64
            then "-isystem ${darwin.apple_sdk.Libsystem}/include" else "";
        shellHook = ''
          . ./.envrc
        '';
      };
    });
}
