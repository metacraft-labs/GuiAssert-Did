{
  description = "GuiAssert-Did - D-ID talking-head plugin for GuiAssert";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        {
          devShells.default = pkgs.mkShell {
            # D-ID is a commercial HTTP API, so this plugin has no
            # Python / no model weights / no GPU toolchain — just a
            # pure-Nim HTTP client plus the supporting bits the tests
            # use to synthesise audio + verify rendered MP4s.
            packages = with pkgs; [
              nim
              nimble
              just
              git
              curl
              ffmpeg-full
              openssl
              cacert
            ];
            shellHook = ''
              # Make Nim's httpclient pick up the system CA bundle so
              # TLS to api.d-id.com works without user setup.
              export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              echo "GuiAssert-Did dev shell ready."
              echo "  nim:      $(nim --version | head -1)"
              echo "  ffmpeg:   $(ffmpeg -version | head -1)"
              echo "  openssl:  $(openssl version)"
              echo
              if [ -z "$DID_API_KEY" ]; then
                echo "NOTE: DID_API_KEY is not set."
                echo "      Pure tests + mock-server tests work without it."
                echo "      The -d:didLive test requires it (set via: export DID_API_KEY=...)."
              else
                echo "  DID_API_KEY: set (length=$${#DID_API_KEY})"
              fi
              echo
              echo "Next steps:"
              echo "  just test        # pure + mock-server tests"
              echo "  just test-live   # live render against api.d-id.com (requires DID_API_KEY)"
            '';
          };
        };
    };
}
