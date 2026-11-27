# Dependency provenance

## Odin UI

The application consumes the unmodified source package declared in
[`nix/odin-ui.nix`](../nix/odin-ui.nix), through generated `.vendor/odin_ui/`.
The canonical source-package recipe verifies the selected version and retains
upstream files/licenses; `tools/prepare_dependencies.py` publishes the ordinary-file
view atomically. Selected payload provenance:

1. Version: 0.2.11
2. Repository: https://github.com/IgneousRed/odin-ui
3. Immutable revision: `4e3401cf9d7a215a8e41bde297e1b9c1dbd9bfc9`
4. ZIP: https://github.com/IgneousRed/odin-ui/releases/download/v0.2.11/odin_ui-v0.2.11.zip
5. ZIP SHA-256: `390eacebdd5e6292209cef94261297d4c39a40aa48a5386ca10c415c8e640830`
6. Published checksums: https://github.com/IgneousRed/odin-ui/releases/download/v0.2.11/SHA256SUMS.txt
7. License: MIT; retained as `.vendor/odin_ui/LICENSE` and web `ODIN-UI-LICENSE.txt`.

Application-specific UI remains outside this package; the retained compatibility
API remains in use.

## Native and WebAssembly dependencies

`flake.lock` and the canonical expressions under `nix/` select Odin, matching
native Raylib, the WebAssembly Raylib recipe, SDK, Node and browser tools. No
installed Homebrew version or project-local source resolver selects runtime
dependencies. See [setup and dependency management](../README.md#shared-dependency-management).
