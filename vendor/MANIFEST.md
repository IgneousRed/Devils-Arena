# Dependency provenance

## Odin UI

The application consumes the unmodified source package declared in
[`nix/odin-ui.nix`](../nix/odin-ui.nix), through generated `.vendor/odin_ui/`.
The canonical source-package recipe verifies the selected version and retains
upstream files/licenses; `tools/prepare_dependencies.py` publishes the ordinary-file
view atomically. Selected payload provenance:

1. Version: 0.2.12
2. Repository: https://github.com/IgneousRed/odin-ui
3. Immutable revision: `f6da54bc8c8e0ba2d8f25fb67532002a5475b6b0`
4. ZIP: https://github.com/IgneousRed/odin-ui/releases/download/v0.2.12/odin_ui-v0.2.12.zip
5. ZIP SHA-256: `a37aeb694fd176eae1347b5921ab6d4bdf301c3e4a92c808b0fec76170ad6beb`
6. Published checksums: https://github.com/IgneousRed/odin-ui/releases/download/v0.2.12/SHA256SUMS.txt
7. License: MIT; retained as `.vendor/odin_ui/LICENSE` and web `ODIN-UI-LICENSE.txt`.

Application-specific UI remains outside this package; the retained compatibility
API remains in use.

## Native and WebAssembly dependencies

`flake.lock` and the canonical expressions under `nix/` select Odin, matching
native Raylib, the WebAssembly Raylib recipe, SDK, Node and browser tools. No
installed Homebrew version or project-local source resolver selects runtime
dependencies. See [setup and dependency management](../README.md#shared-dependency-management).
