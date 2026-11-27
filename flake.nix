{
  description = "Locked development tools for Devil's Arena";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/619c39f6eac5d1ed6b8f073a9414baf7034b2356";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-linux" ];
      projects = nixpkgs.lib.genAttrs systems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          inherit (pkgs) lib;
          legacyToolchain = import ./nix/toolchain.nix { inherit pkgs; };
          toolchain = if system == "aarch64-darwin"
            then import ./nix/llvm23/llvm23-toolchain.nix { inherit pkgs; }
            else legacyToolchain;
          python = toolchain.python or pkgs.python3;
          git = if system == "aarch64-darwin"
            then toolchain.git
            else pkgs.git;
          nixpkgsLock = (builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nixpkgs.locked;
          odinLintSource = pkgs.callPackage ./nix/odin-lint-source.nix { };
          odinLint = pkgs.callPackage ./nix/odin-lint.nix {
            odin = toolchain.odin;
            stdenv = if system == "aarch64-darwin" then toolchain.llvmPackages.stdenv else pkgs.stdenv;
            inherit (odinLintSource) src version;
            revision = odinLintSource.rev;
          };
          odinFuzzSource = pkgs.callPackage ./nix/odin-fuzz-source.nix { };
          odinFuzz = pkgs.callPackage ./nix/odin-fuzz-package.nix {
            inherit (toolchain) odin llvmPackages;
            python3 = python;
            inherit (odinFuzzSource) src version;
            patches = [];
          };
          odinUi = import ./nix/odin-ui.nix { inherit pkgs; };
          nodejs = pkgs.nodejs_26;
          emscripten = pkgs.callPackage ./nix/emscripten.nix { inherit nodejs; python3 = python; };
          webRaylib = pkgs.callPackage ./nix/web-raylib.nix { inherit emscripten nodejs; };
          browser = pkgs.callPackage ./nix/browser-toolchain.nix { inherit nodejs; };
          variables = {
            ODIN = "${toolchain.odin}/bin/odin";
            ODIN_ROOT = "${toolchain.odin}/share";
            ODIN_UI_SOURCE = "${odinUi}";
            EMCC = "${emscripten}/bin/emcc";
            NODE = "${nodejs}/bin/node";
            EM_FROZEN_CACHE = "1";
            RAYLIB_WEB_LIB = "${webRaylib}/lib/libraylib.web.a";
            RAYLIB_WEB_LICENSE = "${webRaylib}/share/licenses/raylib/LICENSE";
          } // lib.optionalAttrs (system == "aarch64-darwin") browser.environment;
          fuzzVariables = {
            ODIN = "${toolchain.odin}/bin/odin";
            ODIN_ROOT = "${toolchain.odin}/share";
            ODIN_UI_SOURCE = "${odinUi}";
            ODIN_FUZZ = "${odinFuzz}/bin/odin-fuzz";
            ODIN_FUZZ_SCANNER = "${odinFuzz}/libexec/odin-fuzz-scan";
            FUZZ_ODIN = "${toolchain.odin}/bin/odin";
            FUZZ_ODIN_ROOT = "${toolchain.odin}/share";
          };
          unset = [ "EMSDK" "EMSDK_NODE" "EMSDK_PYTHON" "EM_CONFIG" "EM_LLVM_ROOT"
            "EM_BINARYEN_ROOT" "EM_CACHE" "ODIN_LINT_CACHE" "DEV_POOL_ROOT"
            "ODIN_FUZZ" "ODIN_FUZZ_SCANNER" "FUZZ_ODIN" "FUZZ_ODIN_ROOT" ]
            ++ lib.optionals (system != "aarch64-darwin") [ "PLAYWRIGHT_MODULE" "PLAYWRIGHT_PACKAGE"
              "PLAYWRIGHT_NODE_MODULES" "PLAYWRIGHT_BROWSERS_PATH" "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"
              "CHROMIUM_BIN" "WEBKIT_BIN" ];
          manifest = pkgs.writeTextDir "share/project-environment.json" (builtins.toJSON {
            schema = 1;
            inherit variables unset;
          });
          fuzzManifest = pkgs.writeTextDir "share/project-environment.json" (builtins.toJSON {
            schema = 1;
            variables = fuzzVariables;
            unset = lib.subtractLists (builtins.attrNames fuzzVariables)
              (unset ++ builtins.attrNames variables);
          });
          updateMetadata = {
            schema = 1;
            dependencies = [
              { name = "nixpkgs"; kind = "github-revision"; repository = "NixOS/nixpkgs";
                ref = "nixpkgs-unstable"; current = nixpkgsLock.rev; }
              { name = "Odin"; kind = "github-release"; repository = "odin-lang/Odin";
                current = toolchain.odin.version; }
              { name = "odin-lint"; kind = "github-revision"; repository = "IgneousRed/odin-lint";
                ref = "main";
                current = odinLintSource.rev; }
              { name = "odin-fuzz"; kind = "github-revision"; repository = "IgneousRed/odin-fuzz";
                ref = "main";
                current = odinFuzzSource.rev; }
              { name = "Odin UI"; kind = "github-release"; repository = "IgneousRed/odin-ui";
                current = odinUi.version; }
              { name = "nodejs"; kind = "nodejs"; current = nodejs.version; }
              { name = "Emscripten"; kind = "json-version";
                url = "https://raw.githubusercontent.com/emscripten-core/emsdk/main/emscripten-releases-tags.json";
                path = [ "aliases" "latest" ]; current = emscripten.version; }
            ] ++ lib.optionals (system == "aarch64-darwin") [
              { name = "LLVM"; kind = "github-release"; repository = "llvm/llvm-project";
                current = "llvmorg-${toolchain.llvmPackages.llvm.version}"; }
              { name = "Playwright"; kind = "npm"; package = "playwright";
                current = browser.playwright.version; }
            ];
          };
          updates = pkgs.writeTextDir "share/dependency-updates.json" (builtins.toJSON updateMetadata);
          commonTools = [ python git pkgs.gnumake pkgs.bash pkgs.coreutils pkgs.curl ];
          environment = pkgs.buildEnv {
            name = "devils-arena-dev-environment";
            paths = commonTools ++ [
              toolchain.odin toolchain.llvmPackages.clang toolchain.llvmPackages.llvm
              emscripten nodejs odinLint manifest updates ]
              ++ lib.optionals (system == "aarch64-darwin") [ browser.playwright browser.browsers ];
            pathsToLink = [ "/bin" ];
            postBuild = ''
              mkdir -p "$out/share"
              ln -s ${manifest}/share/project-environment.json "$out/share/project-environment.json"
              ln -s ${updates}/share/dependency-updates.json "$out/share/dependency-updates.json"
            '';
          };
          fuzzEnvironment = pkgs.buildEnv {
            name = "devils-arena-fuzz-environment";
            paths = commonTools ++ [ toolchain.odin toolchain.llvmPackages.clang
              toolchain.llvmPackages.llvm odinFuzz fuzzManifest updates ];
            pathsToLink = [ "/bin" ];
            postBuild = ''
              mkdir -p "$out/share"
              ln -s ${fuzzManifest}/share/project-environment.json "$out/share/project-environment.json"
              ln -s ${updates}/share/dependency-updates.json "$out/share/dependency-updates.json"
            '';
          };
        in {
          inherit environment fuzzEnvironment;
          dependencyCheck = (import ./nix/dependency-check.nix pkgs updateMetadata)
            // lib.optionalAttrs (system == "aarch64-darwin") {
              preferredPython = "${python}/bin/python3";
            };
          shell = pkgs.mkShell {
            packages = [ environment ];
            shellHook = lib.concatStringsSep "\n" (
              map (name: "unset ${name}") unset
              ++ lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") variables
              ++ [ "export PROJECT_ROOT=\"$PWD\""
                "export PROJECT_NIX_ENVIRONMENT=${environment}"
                "python3 tools/prepare_dependencies.py" ]);
          };
        });
    in {
      lib.dependencyCheck = nixpkgs.lib.mapAttrs (_: project: project.dependencyCheck) projects;
      packages = nixpkgs.lib.mapAttrs (system: project:
        { dev-environment = project.environment; }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          fuzz-environment = project.fuzzEnvironment;
        }) projects;
      devShells = nixpkgs.lib.mapAttrs (_: project: { default = project.shell; }) projects;
    };
}
