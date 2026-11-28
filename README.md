# Devil's Arena

The application version is recorded in [VERSION](VERSION). Replay compatibility
uses the exact build identity, independently of this version.

An Odin/raylib battle prototype targeting WebAssembly. The current application
provides a Warlock-inspired practice battle. Pick spell items, enter a circular
arena, and fight a stationary dummy with aimed spells and knockback. The arena
shrinks over one minute; cumulative lava exposure increases damage outside it. A
battle ends on defeat or after one simulated minute, when the higher remaining HP wins.

Controls: **WASD** move, **mouse** aims, **Q** Fireball, **E** Lightning,
**R** Meteor, **F** Teleport, **Space** Swap. Hold several spell keys to cast
each independently whenever ready. Only picked items enable their spells. The
camera follows the player. Aiming exactly at the character targets the opponent.
Every Battle starts all six stats at 100 and spells
on full cooldown; Speed changes cooldown progression, and Armor, critical, and
dodge affect incoming spells. Restart restores stats, positions, cooldowns, and
lava exposure while keeping items; Pick items returns to the picker. Items are
free in this practice version; the Token economy and full match progression remain future work.

Save/load buttons and **F5/F9** preserve the complete battle. The state inspector
and simulation-speed control remain below the arena. Battle readouts show both
players' HP, Armor, and cumulative lava exposure; the inspector shows the selected
combatant's critical/dodge chances and cooldown progression rate. Version-one and version-two
saves and development snapshots migrate automatically to version three. Development
recovery also retains the original snapshot under its source version. Battle state uses 100 Hz ticks.
Unfocused windows pause combat; long frame stalls cap catch-up to 0.1 seconds.
Legacy compatible stats, active spells, cooldowns, positions, and UI survive migration.
New Reflex and Mastery start at 100; Agility is removed and negative legacy stats
clamp to zero. A legacy seed and lava exposure start at zero because neither was
recorded. If combat encounters an undefined zero-stat ratio, it pauses and shows
a notice while retaining progress. Restarting restores the new base stats.
Power scaling and the zero-denominator rules remain deferred.

Run the debug web application from the project root:

```sh
./scripts/run.sh
```

Open the printed URL (normally `http://localhost:8001`). The server watches source
files, builds without optimization with debug symbols, and preserves the active
session across successful updates. Use `--port 8002` to choose another port.
The narrow status endpoint is `/__dev/status`.

Install [Nix](https://nixos.org/download/) once before using the project commands.
The public scripts enter the exact environment from `flake.nix`/`flake.lock` and
`nix/`; they work from a Git checkout or extracted source archive. Only explicitly
listed source/metadata inputs enter Nix evaluation; generated results and caches
stay outside it. Missing Nix produces a prerequisite error, never another installer.

The compiler remains Odin `dev-2026-11a` (`9a6991685`/`9a69916`), with matching LLVM
and Raylib 6.2. Apple Silicon macOS uses the verified LLVM 23.1.6 bundle in
`nix/llvm23/` and Python 3.15.2 rebuilt with that compiler. Linux retains the
existing catalog toolchain. Emscripten keeps its coupled LLVM 24 bundle.
The SDK, Node, Python, first-party tools and browser dependencies
are immutable Nix outputs; installed Homebrew versions do not select dependencies.
Web/native build tooling supports Apple Silicon macOS 26 and x86-64 Linux. The pinned
native browser bundle and fuzz tool require Apple Silicon macOS; this browser
bundle requires macOS 26. macOS SDK/Xcode Command Line Tools remain system prerequisites.

Prepare the locked web artifacts and generated Odin UI view with:

```sh
./scripts/setup-web.sh
```

No existing cache, sibling checkout or personal skill is required. Nix shares
identical dependencies across projects. The SDK's upstream cache is prepared and
frozen in its Nix derivation; missing variants fail explicitly and must be added
to that canonical recipe. Runtime cache overrides are not used. Source assets
remain in the repository. Odin UI is copied atomically from its locked package to
ignored `.vendor/odin_ui/`, preserving the `odin_ui` collection and licenses.

Build deployable web files explicitly:

```sh
./scripts/build.sh
```

Upload the contents of `.work/build/web/` to a static web host that serves `.wasm`
as `application/wasm`. No backend is required for the deployed game. Player saves
use this browser origin's `localStorage`; development recovery uses separate,
per-tab `sessionStorage`. The release build omits development inspection and
recovery exports. `./scripts/build.sh debug` creates a standalone debug build;
`./scripts/build.sh native` builds the optional desktop application.

Run checks:

```sh
./scripts/check.sh
./scripts/check.sh browser
```

The first command checks Odin code and shared lint policies, transaction/codec
and combat invariants, headless replays, atomic web publication, development recovery, shell/JavaScript
syntax, and native/debug/release builds. The second adds
Chromium and WebKit coverage for browser input, HiDPI, scrolling, saves, source
reload, and recovery. `scripts/browser.sh` uses the exact Nix-owned Playwright
module and native Chromium/WebKit bundles; it does not run npm or download browsers.
For a focused run, use `./scripts/browser.sh tests/browser.mjs --engine=webkit`
(or `--engine=chromium`); the default browser check retains both engines and the
release checks always run. Fixtures and screenshots stay in `.work/browser-*/` and use an isolated local server.
Test web builds stay in `.work/` and leave the deployable `.work/build/web/` output unchanged.

For a per-invocation compiler thread limit, set `ODIN_THREAD_COUNT` to a positive
decimal integer. The existing compiler entrypoint forwards it without replacing
the locked compiler or changing other flags; an explicit compiler argument wins.
The fuzz driver forwards the same count to both seed generation and the supported
upstream `--thread-count` option (or accepts that option directly). With neither
setting, the fuzz driver retains upstream's two-thread default. For one-thread
finishing, including any initial Nix package realization:

```sh
NIX_CONFIG='cores = 1' ODIN_THREAD_COUNT=1 ./scripts/commit-check.sh browser
```

Before committing, run the applicable checks above and the fuzz check:

```sh
./scripts/fuzz.sh
```

`./scripts/commit-check.sh` checks upstream dependency availability, runs the full
local checks, then fuzzes; append `browser` for both headless browser engines.
`./scripts/check-deps` reports updates without changing locks; failed network or
unsupported checks fail rather than report that dependencies are current.

Fuzzing uses the Nix-owned `odin-fuzz` 0.5.0 package at published commit
`ed06f23bea76601e44efc9c5c13e42e54b1b9f14` with the canonical patch-free Nix
package recipe. Source identity is in `nix/odin-fuzz-source.nix`; the package
owns the immutable scanner and matching LLVM/ASan tools. The consumer does not
fetch or build another tool copy. Apple Silicon macOS, `/usr/bin/sandbox-exec`,
and the platform's SDK tools are required. Unsupported hosts fail instead of skip.
The packaged fuzzer uses the shared LLVM 23 compiler/scanner boundary. It remains
lazy and separate from the ordinary development environment: `scripts/fuzz.sh` enters `scripts/dev --profile fuzz`.
Normal build/check/run commands do not realize or retain that profile.
Its locked `FUZZ_ODIN` selection
is separate from the application's compiler; changing the application backend
does not substitute a compiler inside that package boundary.
Normal and direct runner calls evaluate this checkout's locked environment before
selecting its tool, scanner and compiler. Ambient `PATH`, `ODIN_FUZZ*` overrides
and inherited environment markers cannot select substitutes; unavailable locked
dependencies stop the check before any fuzz command runs.
When consulting upstream, read only its
[GUIDE.md](https://github.com/IgneousRed/odin-fuzz/blob/ed06f23bea76601e44efc9c5c13e42e54b1b9f14/GUIDE.md),
never implementation source.

`odin-fuzz.json` selects the windowless combat application in `apps/headless/`.
The wrapper copies the current project into private scratch, supplies its exact
build identity, and generates a valid replay below 4 KiB through `--example`. Seed
overrides enter through the application's `--seed` option. This exercises real
replay decoding, combat procedures and engine commits. Native window/input,
rendering, browser integration and player-storage/recovery I/O are outside this
fuzz target; retain their existing verification.

The default exploration budget is 30 seconds, excluding builds and confirmation;
use `./scripts/fuzz.sh --budget 120 --seed 2` for a longer search. Necessary
unresolved evidence is retained under `.local/fuzz/triage/`; reusable
corpus cases are stored under `.local/fuzz/corpus/`, separated by build
identity because replay inputs require the matching build. The command requires
successful application execution with LLVM coverage guidance and rejects tool
failures, confirmed bugs, timeouts and withheld failures using `summary.json`
only. Actual finding evidence, remediation and reproduction belong exclusively to
the project's authorized Gemini 4 Neon triage workflow. Ordinary setup and
infrastructure diagnosis uses the supported guide and safe summary. New retained
unresolved runs root their Nix environment closure. Clean campaigns remove their
temporary source captures and binaries from `.work/fuzz/`, retaining only corpus
and the latest safe summary/setup record in `.local/fuzz/`. Findings-free
exploration is bounded evidence, not a proof of correctness.

See [ARCHITECTURE.md](ARCHITECTURE.md) for data ownership, package boundaries, and
the transaction and recovery contracts. [Implemented gameplay](docs/gameplay.md) documents the
practice rules without depending on private records. Intended design, open
questions, work records, experiments and historical notes are maintained in a
separate optional private repository; they are not required to build or use the game.

## Project storage

Generated native/web outputs use `.work/build/`, and package staging uses
`.work/package/`. Persistent reproducible dependency views use `.vendor/odin_ui/`,
verified against the immutable Nix payload. Recipes, pins, checksums, licenses and
reference fixtures remain public; builds never modify pristine dependency sources.
`.vendor/` is ignored and excluded from both public and private uploads. `.work/` is disposable:
completed tasks must not leave crucial information there.

Native saves use `.local/data/save.json`; an existing `binaries/save.json` remains
readable if no new-location save exists. The next save writes atomically to the
new location without deleting the legacy original. Native application recordings
use `.local/recordings/`. Existing recordings may be moved there unchanged; replay
accepts an explicit file path and still requires its matching build. Do not delete
the only playback build if it cannot be reproduced. Browser localStorage and
sessionStorage keys, default localhost origin, schema and reload recovery are
unchanged; do not clear them when cleaning generated files.

`.private/` is an independent optional private Git checkout for deliberately
approved records. `.local/` contains necessary machine-only data and a concise
purpose/removal index; never upload it, even privately. Neither is a public build
input. Both, and `.work/`, are excluded from public Git/source exports/packages.
Enable the local source-path guards with `git config core.hooksPath .githooks`.
New or unknown paths require review before publication.

Record and replay an application session:

Open **Replay tools** at the lower right of the browser and choose **Download recording**.
Recording starts automatically when the application starts, including during item
picking. A `.jsonl` recording includes the initial state, every sampled frame input
(keys, pointer, viewport, pixel ratio, scroll, focus and elapsed time), Save/Load
results and exact returned bytes, and development-restore payloads. Inputs are
recorded before they are interpreted as commands, including ignored or failed actions.
It records game-facing system-call results, not an operating-system syscall trace.
Runtime/GPU handles are reconstructed from the same build's resources.

Choose a file under **Replay recording** to play it in an isolated instance of the
same build and compare its final facts, UI and notice with the recording. Playback
uses the recorded timing and storage results without reading or writing player
storage. Closing the replay returns to the unchanged live session.
Recordings from another build are rejected; there is no replay migration.
`scripts/odin-ui.sh` stamps the sources, compiler, platform, behavior-changing build
flags and linked web raylib archive into the build identity. Keep the original
build to replay its recordings. Player-save and development-recovery migrations
remain supported separately.

Browser recording is held in memory in the current page, up to 64 MiB. Download
before refreshing, closing, or changing source; development reload starts a new
recording. Reaching the limit shows an incomplete-recording error rather than
silently discarding inputs or exporting a misleading complete replay.
Native launches write timestamped `.jsonl` files under `.local/recordings/`;
a normal window close appends the final-state check. Interrupted native traces can
replay their captured prefix with an explicit incomplete-recording notice, ignoring
a torn final record. An incomplete trace also withholds a final Frame without a
following storage result, since that response may have been lost. Native capture
stops with a warning before exceeding 64 MiB
and retains its incomplete prefix. Close the native replay window to cancel playback.
Use the same executable with
`--replay .local/recordings/<recording>.jsonl` for native playback.

Run combat without a window:

```sh
mkdir -p .work
./scripts/headless.sh --example > .work/replay.json
./scripts/headless.sh .work/replay.json > .work/result.json
./scripts/headless.sh .work/replay.json --scale 7 --repeat 100 > .work/scaled-result.json
./scripts/headless.sh .work/replay.json --trace-every 10 > .work/traced-result.json
```

The script builds `.work/build/headless`. Reuse that executable directly when running
many cases. It uses the same combat procedure and transaction constraints as the
application, with explicit inputs for both players. It does not train an NN.

The example emits replay `version` 3, a `build` identity, `initial` (a complete version-three player
save with an active Battle), and `steps`. The seed is stored once in
`initial.facts.battle.seed` as an unsigned 32-bit integer. Each step has a positive
`ticks` count and an `inputs` array ordered by player. Each input contains
`move_x`, `move_y`, `aim_x`, `aim_y`, and `casts`. Casts are a numeric bit mask:
Fireball=2, Lightning=4, Meteor=8, Teleport=16, Swap=32; add the values for held
spells, or use 0 for none. Movement and aim use arena coordinates. A step holds
its ground target fixed and its cast buttons pressed for all its Ticks.
Total requested Ticks cannot exceed 6000; simulation stops early when the Battle
ends. Replay JSON is limited to 4 MiB and rejects missing/unknown fields, partial
arrays, invalid cast bits, invalid initial state, and a different application build.
Older replay formats are rejected; replay conversion is intentionally unsupported.

`--scale` multiplies all six initial combat stats and starting HP by one positive
factor, leaving geometry, cooldown durations, time, and seed unchanged. `--repeat`
restarts from that same initial state and seed each time. Output contains the seed,
repetition count, total simulated Ticks, and `final`, a player save from the last
run. Its facts can be used as another replay's initial state if the Battle is
still active. Critical and dodge rolls are reconstructed from the saved seed and
Tick, so recovery and replay need no hidden RNG state. New practice Battles
increment the previous Battle's seed; returning to the picker retains it.
The example inventories are inspection fixtures, not a self-play inventory policy.

Use `--trace-every N` to inspect a trajectory at an interval of 1–6000 simulated
Ticks. The optional `trace` array contains complete player-save objects: the scaled
initial state, each N-Tick sample measured from that state, and the final state.
Early defeat always includes its final state, and an aligned final sample appears
only once. Each active snapshot can serve as another replay's `initial`, with
the corresponding remaining inputs and the same matching build. With `--repeat`,
only the last run is traced; sample storage does not grow with repetition count.
Without this option, output has its original shape and no snapshots are collected.
Traces explain state changes at the chosen interval; they are not an exact
per-effect event log or an NN policy.

Generate diagrams of the stored game data:

```sh
./scripts/build-dbml.sh
```

Open `.work/build/schema/runtime.dbml` or `.work/build/schema/persistence.dbml` in VS Code
and run **DBML: Open Preview to the Side** using the dbdiagram extension. Runtime
shows the authoritative store; persistence shows player-save and development-reload
payloads. The script reads compiled Odin types, including fields, enum values and
array dimensions, so rerun it after changing state definitions. It requires only
Odin and a shell, and works from any directory.

Boxes represent types and lines represent inline containment. The `__diagram_id`
fields exist only to connect boxes in DBML; they are never stored. Array positions
are the game's row keys. Notes explain index relationships and which values are
saved. Derived views, commands, engine bookkeeping and runtime resources are excluded.
Generated diagrams stay under the ignored `.work/build/` output directory.

The project's original source code is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE), with a required copyright notice
crediting IgneousRed. The web build includes these terms as `LICENSE.txt`.

Third-party code and assets retain their respective licenses. Asset credits and
license notices are recorded in [assets/README.md](assets/README.md).

## Shared UI dependency

The generated `.vendor/odin_ui/` view contains the unmodified locked Odin UI source
package. Its release ZIP and checksum are defined in `nix/odin-ui.nix`; the
[vendor manifest](vendor/MANIFEST.md) records provenance and licenses. The selected
release is 0.2.12 at commit `f6da54bc8c8e0ba2d8f25fb67532002a5475b6b0`.
`scripts/odin-ui.sh` registers this ordinary-file view as collection `odin_ui`;
application imports remain `odin_ui:raylib`. Web output retains `ODIN-UI-LICENSE.txt`.

Check newer releases before every commit, but adopt changes explicitly. Update
the source pin/checksum, prepare the generated view and run the affected browser
checks. Application-specific UI remains outside the package; reusable fixes
belong upstream. The application retains the compatibility API; the generated
[MIGRATING.md](.vendor/odin_ui/MIGRATING.md) describes the two-pass API.

## Shared Odin linter

After editing code, run the applicable Odin compiler checks, then the shared
linter before completing the change:

```sh
./scripts/lint.sh
```

This command first checks the native application, both `js_wasm32` browser
configurations (`RAYLIB_WASM_LIB=env.o`, `WEB_DEVELOPMENT=true/false`), schema and
headless entry points with maximal first-party vetting and strict style, then
compiles/runs the engine, application, schema and headless Odin tests. The flags
are `-vet -vet-tabs -vet-using-param -vet-nil-deref -vet-uninitialized
-vet-atomic-access -strict-style -warnings-as-errors`, with explicit first-party
package scopes. Separate `-vet-unused-procedures` passes cover the closed native,
browser development/release, schema and headless entry points; attributed tests
retain every other check. The pinned compiler incorrectly reports `@(test)`
procedures as unused even under `odin test`. Only success invokes the packaged analyzer:

```sh
./scripts/dev odin-lint \
  --root . --source-root src --collection odin_ui=.vendor/odin_ui \
  src apps/headless scripts/schema tests
```

Use `./scripts/lint.sh` for the compiler precondition; the analyzer invocation alone
does not check or compile the application. All shared rules always run on
project-owned Odin, with the complete repository as consumer scope. Vendored
Odin UI is mapped for imports and excluded from lint selection. The project's
explicit dependency exceptions in [ARCHITECTURE.md](ARCHITECTURE.md#package-boundaries)
remain authoritative. Shared linter v0.7.7 supports the project's direct data,
pure validation and migration dependencies. Report any policy conflicts without
filtering diagnostics or refactoring the approved architecture.

Version 0.7.7 runs all 27 active rules. The linter checks source policy and
FRP state boundaries, including known effects, protected-state writes,
transactions and source-established publication preconditions. It does not check
general memory/allocator lifetimes or require every copy to be a destructive
transfer. `LINT003`/`LINT004` and `OWN003`/`OWN004` are retired upstream.
Missing semantic evidence is nonblocking; a clean result does not certify unknown
behavior. Public exports remain API boundaries regardless of saved local uses.
No consumer suppression or filtering is used.

Exit `0` is clean, `1` means lint findings, and `2` means shared setup/analysis
failed. Analyzer signals or unexpected exit statuses are reported as analysis
failures with exit `2`. Setup or analysis failures are never a pass. The full commands
`./scripts/check.sh` and `./scripts/check.sh browser` run their other checks and
builds before the same compiler/lint gate, preserving non-lint verification even
when shared policy findings remain. `SIMPLIFY001` is an imperative lint error;
review its eligibility and semantic safety before inlining. A retained finding
continues to fail verification.

The Nix package uses exact published source
`6cca8868fa34b8ddd291e358ae640571a60c80e4` from `IgneousRed/odin-lint`, declared in
`nix/odin-lint-source.nix`. Its canonical package recipe retains the compiler
identity guard. The retained standalone runner supports `ODIN_LINT_THREAD_COUNT=1`
per invocation; its effective thread setting participates in cache identity.
Runtime linting uses the packaged CLI, without a project-local
source/bootstrap cache, sibling checkout or installed skill.

For explicit upgrades, review the selected full published commit and its
integration/rule documentation, update the authoritative source declaration and
canonical recipe as needed, and run `./scripts/commit-check.sh browser`. Moving
an upstream branch or installing another compiler does not change the lock.

## Shared dependency management

`flake.lock` pins the common nixpkgs source. `nix/` holds the exact tool/source
recipes and browser metadata; the environment manifest supplies their immutable
paths. `scripts/dev COMMAND ...` is the common entry point, including for source
archives. It realizes `packages.<system>.dev-environment`, applies its manifest,
and runs in the original project directory. Public launch/build/check scripts
enter this environment automatically. For evaluation without realization, use
`scripts/dev --eval ATTRIBUTE`, optionally adding Nix evaluation arguments such
as `--raw --option allow-import-from-derivation false`. This uses the same
declared-input staging; avoid raw `path:` references to a populated project.

Before each commit, `scripts/check-deps` uses metadata generated from these
source declarations to report available updates. It never rewrites locks or
silently changes selected versions. The project environment has a GC root under
`.work/nix/`; new retained fuzz captures keep their own closure root until those
captures are deliberately removed. Existing recovery files, results and captures
are preserved.

The dependency checker uses the rebuilt Python when it is already realized and
registered in Nix; otherwise it downloads only its declared public Python
bootstrap, with source builds disabled. Successful reports retarget the checker
cache root, while failures preserve the previous root.
