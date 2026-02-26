{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crate2nix = {
      url = "github:tgunnoe/crate2nix";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, crate2nix, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [ inputs.rust-overlay.overlays.default ];
      };
      isDarwin = pkgs.lib.hasSuffix "darwin" system;
      isDarwinAArch64 = system == "aarch64-darwin";

      # Load toolchain from rust-toolchain.toml
      rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

      # crate2nix tools for IFD-based Cargo.nix generation
      crate2nixTools = import "${crate2nix}/tools.nix" { inherit pkgs; };

      # Pre-committed Cargo.nix build (fast, no IFD)
      crate2nixBuild = import ./nix/crate2nix/package.nix {
        inherit pkgs rustToolchain;
        src = ./.;
      };

      # IFD build: generates Cargo.nix at eval time from Cargo.lock
      ifdCargoNix = crate2nixTools.generatedCargoNix {
        name = "midnight-node";
        src = ./.;
        cargo = rustToolchain;
      };
      ifdBuild = import ./nix/crate2nix/package.nix {
        inherit pkgs rustToolchain;
        src = ./.;
        cargoNixPath = ifdCargoNix;
      };

    in {
      # Default: pre-committed Cargo.nix (no IFD)
      packages = {
        midnight-node = crate2nixBuild.midnight-node;
        midnight-node-toolkit = crate2nixBuild.midnight-node-toolkit;
        default = crate2nixBuild.midnight-node;
        # IFD variants: generate Cargo.nix at eval time
        midnight-node-ifd = ifdBuild.midnight-node;
        midnight-node-toolkit-ifd = ifdBuild.midnight-node-toolkit;
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
