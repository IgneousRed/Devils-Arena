# Dependency provenance

## Odin UI

The application consumes the unmodified source package declared in
[`nix/odin-ui.nix`](../nix/odin-ui.nix), through generated `.vendor/odin_ui/`.
The canonical source-package recipe verifies the selected version and retains
upstream files/licenses; `tools/prepare_dependencies.py` publishes the ordinary-file
view atomically. Selected payload provenance:

1. Version: 0.2.10
2. Repository: https://github.com/IgneousRed/odin-ui
3. Immutable revision: `b25036bc4fb674fe391a1e64ef2534d576861d5d`
4. ZIP: https://github.com/IgneousRed/odin-ui/releases/download/v0.2.10/odin_ui-v0.2.10.zip
5. ZIP SHA-256: `3ced914bf2bf9ebf1a669422cdb963c03b2f5bf0087a0f0d91efc189cf1d3483`
6. Published checksums: https://github.com/IgneousRed/odin-ui/releases/download/v0.2.10/SHA256SUMS.txt
7. License: MIT; retained as `.vendor/odin_ui/LICENSE` and web `ODIN-UI-LICENSE.txt`.

Application-specific UI remains outside this package; the retained compatibility
API remains in use.

## Native and WebAssembly dependencies

`flake.lock` and the canonical expressions under `nix/` select Odin, matching
native Raylib, the WebAssembly Raylib recipe, SDK, Node and browser tools. No
installed Homebrew version or project-local source resolver selects runtime
dependencies. See [setup and dependency management](../README.md#shared-dependency-management).
