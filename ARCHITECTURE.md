# Functional relational architecture

The application targets WebAssembly using Odin, Emscripten, and raylib. It keeps
the original prototype's two combatants, stat values, activity counters, kill
count, and simulation-speed setting. The practice battle adds item-granted spells,
movement, knockback, lava damage, and one controlled player against a dummy.
The Token economy, Power scaling, full Match progression, and NN training remain
unimplemented. Application-boundary recording captures frame samples and external results.

## Package boundaries

| Package | Responsibility | Project dependencies |
| --- | --- | --- |
| `src/catalog/` | Immutable gameplay definitions and tuning | None |
| `src/state/` | Authoritative relation rows, commands, save and reload schemas | catalog |
| `src/views/` | Reconstructible calculation result types | state |
| `src/functions/` | Pure queries, geometry and strict codecs | views, state, catalog, migrations |
| `src/migrations/` | Retained versioned persistence shapes and pure transformations | state, catalog |
| `src/engine/` | Private live store, transaction snapshots, validation, atomic commits | state, catalog |
| `src/procedures/` | Gameplay transactions and private load staging | engine, functions, views, state, catalog |
| `src/effects/` | Command/commit orchestration, platform storage and recording output | engine, functions, procedures, state |
| `odin_ui:raylib` | Copied layout, text, clipping, scrolling, drawing, and hit testing | Odin core, raylib |
| `src/main.odin`, `src/main_web.odin`, `src/application.odin` | Native interface; browser exports/scratch context; sampled-input processing, UI composition, runtime resources and rendering | Role packages above, raylib |

Imports are acyclic. `views` contains calculated data types, not rendering.
The renderer does not mutate game facts. Storage effects are selected by Odin
build tags; browser builds do not import the native filesystem package.

## Facts and lifetimes

Fixed array positions are primary keys; no pointers or duplicate IDs are stored.
There are two combatant rows, two activity rows, one session row, one UI row,
and one presentation-notice row. Combat adds two fixed inventories of 16 Item
slots, corresponding cooldown rows, two bodies, one Battle row, and 32 spell slots. Each fact is stored once. The catalog contains
immutable names and choices, not a second mutable set of stats.

Combatant rows contain HP, Armor, Power, Speed, Reflex, and Mastery. Activity rows
contain dodges, misses, and move progress. The session row contains the kill count
and an index into the immutable speed choices. UI stores the selected combatant
and scroll offset. Presentation stores a notice enum instead of allocated text.
Zero state is valid: it selects the first combatant, uses 1x simulation speed,
has zero stats and counters, and shows no notice. Starting a Battle resets all
six stats to 100, spawn positions, cumulative lava exposure, and full cooldowns.
Bodies retain starting HP as the scale reference for spell/lava damage and display.
The Battle stores its seed and elapsed Ticks. Critical/dodge draws are pure results
of those two facts, not another mutable RNG state. Validation rejects negative or
non-finite stats, invalid references, non-finite spatial values, impossible lava
exposure totals, and invalid presentation values. Body validators track the Battle
row so lowering elapsed Ticks also rechecks accumulated exposure.

`functions.overview` calculates the selected row's display values, including
critical/dodge chances and relative-Speed cooldown progression. It marks undefined
zero-stat ratios explicitly for the UI instead of inventing probabilities. The
cooldown-rate function is shared with combat. Battle headers show both players'
HP, Armor, and cumulative lava time directly from committed facts. Layout trees,
formatted text, mouse input, and command values are frame-local. An 8 MiB browser
scratch arena is cleared at each frame/export boundary. No tree or arena pointer
is retained in state. The font is embedded from `assets/AtkinsonHyperlegibleNext-SemiBold.ttf`; its GPU handles
are reconstructed at startup. The browser supplies logical dimensions and device
pixel ratio, and drawing and clipping use the same conversion.

The vendored Odin UI package owns layout, hit testing, clipping, and drawing.
The application reuses its hit testing and clipping
rather than implementing a second geometry system.

## Transactions and automatic validation

Only the engine package owns the live store and subscriptions.
`engine.begin()` returns a caller-owned copy and a
revision. Procedures change that private copy; `engine.commit()` rejects stale
transactions, compares typed rows, checks affected constraints, and publishes
facts and subscriptions together. No exported pointer reaches the live store.
A rejected transaction leaves the old facts and subscriptions untouched. A no-op
commit performs no checks after initialization and does not advance the revision.

Each row validator automatically tracks its own row. Typed relation readers record
any additional rows consulted. At commit, a validator reruns only if a changed
row intersects its previous reads. Successful checks replace their subscriptions,
including conditional reads; failed checks publish nothing. Callers maintain no
dirty flags or dependency lists. Dependencies are compact bit sets, so invalidation is
one intersection with the changed-row set. One global ownership constraint tracks
both inventories to reject duplicate ownership; cooldown
validators track their inventory so empty slots cannot retain cooldowns. Active
Battle validation tracks both bodies and combatants, requires positive starting HP,
and rejects defeated active players or terminal results inconsistent with HP and time.
Nonempty spell rows require positive remaining lifetime; unused spell rows are zero.
Additional
relational rules must record every row consulted through the query read tracker. Engine tests cover multiple recorded reads, invalidation and
replacement of real conditional subscriptions as well as ordinary commit behavior.
Rejected transactions report stale revisions or the failing constraint on the
transaction; development effects print this detail without putting it in player UI.

The schema is small enough that copying fixed arrays and comparing typed rows
is simpler than allocation, reflection-based mutation interception, or a query
language. Adding a relation requires its key, typed comparison, reader, and
validator. There is one writer on the application thread.

## Frame and command flow

The application reads an engine snapshot and constructs a layout from a derived
overview. Input resolves against those same layout bounds. A command goes through
`effects.execute`, which calls the reducer or stages a decoded save, then commits.
Input and aiming resolve against the same starting layout and facts. Commands and
ticks are applied before one final rebuild, skipped when the revision is unchanged.
Successful reset/load/Battle transitions discard the old frame's held combat input.
Mouse events
use raylib's edge detection instead of retaining a second set of mouse facts.
After input is consumed, a second composition reuses the frame's caller-owned
UI node storage, reclaimed with the rest of the frame.

The application schedules 100 Hz combat ticks through `effects.tick`, which runs
`procedures.battle_tick` on private facts and commits once per tick. Geometry
queries live in `functions`; spell definitions and tuning live in `catalog`.
Held-key input and the frame accumulator are transient boundary resources;
whole ticks, bodies, inventories, cooldowns and spells are authoritative facts.
The shared procedure accepts inputs for both players. The graphical practice
application supplies an empty input for the dummy. Terminal Battles and pick phases do not tick.
Each Tick samples the starting facts and sums combat-stat, position, and velocity
increments before applying them together. HP and Armor clamp to zero once afterward;
Power, Speed, Reflex, and Mastery remain unchanged by the current spells. Movement, hits, Teleport, Swap, and lava
all read that snapshot. New persistent spells begin advancing on the next Tick.
Procedures reconstruct a private RNG from the saved seed and Tick; the functions
package neither advances generators nor retains random state. Each player receives
independent critical and dodge rolls shared across the Tick's
incoming/outgoing effects. Armor reduces damage and absorbs part of it, including
lava. Weighted stat shares combine binary exponents when an intermediate share
would be subnormal, preserving representable losses across extreme finite ratios.
Held casts preserve cooldown overshoot and use relative-Speed progression;
released ready spells do not activate. Saturated pools resolve persistent activations
in player/spell order, independently of inventory display order. Lightning spans
the square world's diagonal. Instant Lightning
and Teleport gameplay still activates when their cosmetic flash cannot be stored;
persistent projectiles and delayed Meteors reclaim the soonest-expiring cosmetic
slot when necessary, and wait only when gameplay effects occupy every slot.
The circle radius derives from elapsed
Ticks. Lava exposure accumulates across visits; damage uses its squared counter,
a provisional coefficient, and starting HP. Undefined zero-stat ratios leave the
Tick untouched and produce a pause notice, without inventing the deferred rules.
Catch-up is bounded to 0.1 seconds per frame; unfocused windows pause.
The custom arena renderer uses the immediate UI node's resolved bounds and clip,
with the same geometry used for mouse aiming and development inspection. The
camera follows the player; screen-relative mouse coordinates convert to arena
coordinates before entering the simulation.
Browser frames are scheduled by `requestAnimationFrame`, so the Wasm callback
returns control to the browser each frame. Native builds use raylib's frame loop.

## Application recordings

`state.Frame_Input` is a sample of every game-facing query: physical screen dimensions,
pixel ratio, mouse coordinates, focus, elapsed frame time, consumed key states/edges,
left-button press, scroll, and native close. `sample_frame` performs live queries;
`update_game` interprets that sample against the normal layout and advances the same
command/tick path during both live execution and playback.

An ordered JSON-lines stream begins with format/build identity and an initial
reload snapshot. Frame events are emitted before input interpretation. Separate Storage events
are emitted immediately after Save/Load adapter results return, before decoding or
applying them. Playback pairs each result with its preceding frame. A failing frame
therefore retains its input rather than disappearing from the trace. Returned bytes are integer arrays, preserving malformed and non-UTF8
responses exactly. Restore events retain the supplied bytes even when decoding or
validation rejects them. The footer contains the final reload snapshot for an
end-to-end comparison. An interrupted native stream can replay its captured prefix
with an explicit notice that final-state verification is unavailable. Saves and
authoritative fact schemas are unchanged.

Recording output is a boundary resource, separate from facts, saves and recovery.
Native output uses a timestamped file; browser output uses a bounded 64 MiB buffer
and reports exhaustion. Browser playback runs in an isolated same-build iframe,
pauses live frame scheduling, reconstructs layout/GPU resources, explicitly closes
the player's font/window resources on completion or cancellation, and injects stored
Save/Load results instead of calling storage. Fast verification resolves the same
layout and transactions without drawing; visible playback draws each recorded frame.
The recording's initial clock is zero;
subsequent frame samples reconstruct accumulator behavior. Replay never migrates
across application versions. The headless combat replay likewise checks its build
identity and rejects previous formats. Save/recovery migrations are independent.

## Saves and development recovery

Version-three player saves contain only a schema version and `state.Facts`. Loading
resets UI and notices through an explicit transaction. Browser effects store JSON
under `devils-due.save`; desktop effects atomically rename a temporary file to
`.local/data/save.json`. The pure codec rejects omitted or extra fields, incomplete
arrays, unknown versions, invalid enum values, integer overflow, non-finite
numbers, trailing data, and files larger than 16 KiB. A tokenizer pass bounds
nesting before entering the standard recursive JSON parser and rejects integer
literals outside its signed 64-bit range before they can wrap. Larger floating
values use decimal or exponent notation, as produced by the save encoder. Decoding never publishes
state: restored facts must also pass the engine's constraints. Integer destination
checks reuse the parser range for equally wide or wider types, checking signedness
without an overflowing shift; narrower types retain explicit bounds.

Version-three development snapshots contain the whole authoritative store,
including UI and presentation. They exclude revisions, subscriptions, derived
values, transient input and runtime handles. The browser restores through the
same transactional validation boundary before drawing. Retained pure migrations
in `src/migrations/migrations.odin` keep exact old
shapes and explicit source/destination versions. The first adds empty combat
relations. The second preserves compatible combatants, active spells, bodies,
inventories, cooldowns, Battle phase/Ticks, UI, and notices. It removes unused
Agility, adds Reflex/Mastery at 100, and clamps legacy negative stats to zero.
Legacy seeds and lava exposure start at zero; there is no history to reconstruct.
All schemas pass strict structural decoding, then migrated facts pass ordinary
transaction constraints. Zero-Speed legacy Battles restore intact and pause if
their next Tick needs an undefined 0/0 rule. Restart uses the agreed reset rules.
Historical spell identifiers and new-stat migration defaults are frozen in the
migration source; current catalog tuning cannot change the interpretation of v2.
Literal v1/v2 JSON fixtures verify these contracts independently of current types.
The development client retains originals under `devils-due.dev.snapshot.v1` or
`.v2`, adding numeric suffixes for distinct originals from the same source schema.
Repeated restoration of the same original reuses its archive. Archive failure rejects
startup while retaining the active recovery key. Player-save loading does not
rewrite storage. Incompatible snapshots remain rejected without resetting progress.

`scripts/run.sh` starts the debug server. It caches hashes by file identity during
polling, watches the application inputs including the root license, debounces changes,
rehashes all inputs before publication,
builds into a new immutable version directory, and publishes only complete builds
whose sources stayed unchanged during compilation. `/__dev/status` reports that
version and build state. A compile failure retains the last working version.
Old version directories remain available for recovery and older browser tabs.
Filesystem failures while building or publishing report an error and clear the
building status, retaining the previous current-version pointer. Completed but
unpublished output remains available for inspection; a later source edit can retry.
Source-inspection errors during polling retain the working build, report an error,
and retry automatically, including when file access recovers without another edit.

Each debug page includes its own versioned `dev.js`. Before navigation, that client
captures a snapshot and writes per-tab recovery data to `sessionStorage`. Storage
failure leaves the active instance running. The next build restores before its
first frame. Startup is acknowledged only after that frame succeeds, retaining
the rollback target until then. The startup deadline pauses while the tab is hidden
and restarts when visible, since hidden tabs may suspend animation frames.
If startup or restoration fails, the client retains the original
snapshot, blocks that version, and navigates back to the previous build. Player
saves are never used as development snapshots or overwritten during recovery.
Ordinary page refresh captures the latest live state, so an older reload snapshot
cannot overwrite subsequent edits. Status requests run sequentially; startup
failure prevents a late callback from reviving a rejected build.
Snapshot preservation is shared by page exit, runtime failure, and source navigation.
After an acknowledged frame loop fails, the client captures the last committed
state and retains its recovery API and update polling. Its stopped-game explanation
remains visible alongside build/recovery feedback. A source fix can resume that
state when snapshot exports remain usable. Failed capture or storage writes retain
the previous snapshot and prevent unsafe navigation; later polls can retry.
Startup publishes its recovery API only after storage bookkeeping succeeds.
Release output excludes the client and development exports.

## Tooling and verification

Browser control checks hold the press until the recorder confirms the game sampled
it, then wait for the expected application result. A fixture suspends game updates
while browser animation frames continue, demonstrating why animation frames alone
cannot acknowledge input. The historical failed WebKit log does not establish its
exact low-level scheduling path; the new checks directly observe sampling and results.

Public scripts enter the locked Nix environment through `scripts/dev`. The
launcher stages only flake definitions and explicitly allowed metadata, so Git
checkouts and source archives work without capturing results or caches. Nix owns
the compiler, matching native Raylib, WebAssembly archive, SDK and runtime. The
Web archive uses the canonical PLATFORM_WEB/STATIC/OPENGL_ES2 recipe. The SDK's
upstream cache is prepared and frozen inside its Nix derivation; missing variants
fail instead of creating a project cache. Fixtures stay inside `.work/`.

Odin UI is an unmodified locked source package, copied atomically to the ignored
ordinary-file view `.vendor/odin_ui/`. Application imports retain collection
`odin_ui`. Native and browser libraries remain distinct, with matching Odin
bindings; licenses remain in web output.

Generated outputs go in `.work/build/`. Launching always selects an unoptimized debug
build with symbols; `scripts/build.sh` without arguments explicitly builds the
optimized web target. Atomic directory publication on macOS/Linux retains the
previous complete output on compilation/publication failure. Development version
directories remain immutable and keep older working builds for recovery.

`scripts/check.sh` runs Odin vet checks, transaction/codec/combat and headless tests, debug
publication and HTTP tests, shell/JavaScript syntax checks, dependency-free Node
recovery tests, and native/debug/release builds. It finishes with
`scripts/lint.sh`, which requires successful native, browser development/release,
headless and schema compiler checks and Odin tests before invoking the
Nix-owned pinned Odin analyzer. All shared rules run on `src/`,
`apps/headless/`, `scripts/schema/` and `tests/`; there is no consumer analyzer
bootstrap or parallel dependency cache.
Setup/analysis errors and lint findings fail verification.
Shared linter v0.7.7 supports the direct data, pure validation and migration
dependencies in the package map above. Retain that map and report any policy
conflicts without suppressing shared rules.
See [the linter workflow](README.md#shared-odin-linter) for the exact pin,
authentication and upgrade commands. Python uses standard-library tests, shell
uses `bash -n`, and JavaScript uses the SDK's Node syntax checker and tests.
The optional
`browser` argument adds Chromium and WebKit checks with an isolated copied
fixture and an ephemeral local origin. Those checks exercise real Wasm input,
HiDPI, narrow-screen scrolling, saves, rollback, source reload, and incompatible
snapshot recovery. They neither inspect nor disturb other project processes.
Test web builds stay in `.work/` and do not replace `.work/build/web/`. Engine test
declarations use Odin's test-only file directive and are excluded from application
builds.
`scripts/browser.sh` uses the exact Nix-owned Playwright package and native
Chromium/WebKit bundles, with no npm install or browser-download fallback. The
current browser bundle is native Apple Silicon macOS 26; standard Linux web
build/check targets remain separate from this runtime coverage.

`scripts/headless.sh` builds the `apps/headless/` windowless replay application
in `.work/build/headless`. `scripts/fuzz.sh` uses the same application with ASan and
LLVM coverage, an exact build-matched replay seed, and a recorded `--seed`
override. Private source copies and build-specific corpora keep fuzzing separate
from active development sessions. `scripts/commit-check.sh` adds this fuzz gate
after dependency-update checks and the existing local gates. Its stage-one adapter
reads only `summary.json`; actual finding triage belongs to Gemini 4 Neon. New retained
unresolved runs retain their exact Nix environment and opaque evidence under
`.local/fuzz/triage/`; clean runs retain corpus and the latest safe summary/setup
only. Temporary campaigns and source captures stay in `.work/fuzz/` until checked,
then are removed. Persistent corpus lives in `.local/fuzz/corpus/`. GUI, browser
and storage/recovery I/O are outside
the headless fuzz boundary and retain their existing checks.
It advances the same combat procedure and commits through the engine, starting
from a version-three player-save state and explicit Tick-counted inputs for both
players. A replay can be repeated or commonly scaled without altering its source.
Version-three replays hold independent cast buttons, use the seed in the initial
Battle, and require the same source/toolchain/build identity. Previous replay
versions are rejected rather than migrated. This tool does not choose inventories or implement NN training. Its tests cover shared-simulation
equivalence, replay continuation, common scaling, and rejection of invalid inputs.

Optional `--trace-every N` inspection captures only committed states into complete
player-save snapshots. Sampling uses simulated Tick counts relative to the run's
initial state, includes both endpoints, and never duplicates the final sample.
Only the final repetition is captured. Default output omits the trace field and
allocates no snapshot array; game state and save/reload schemas are unchanged.

The [shared UI dependency guide](README.md#shared-ui-dependency) covers collection
registration and release updates. The [vendor manifest](vendor/MANIFEST.md) records
its source, version, archive checksum, and license. Application-specific UI stays
outside the unchanged vendored source.

## Representation decisions

The dependency bit-set implementation replaces per-validator boolean scans with
set intersection, and the changed-row set also detects no-op commits without a
second whole-store comparison. Frame composition remains reconstructible scratch
work and runs at most once for input and once for the final committed state.

A shared version-dispatch JSON prototype passed the codec/migration tests but added
helpers and branches overall; the compact standard decoder remains. A compiled
SoA effect-pool trial reproduced the same final facts in a fixed replay, but changed
JSON into columns, removed aggregate equality, and requires persistence adapters
and diagram support. The measured runs were noisy and did not justify that extra
code for this workload. The authoritative format therefore remains unchanged at
version three. Future changes should start from representative batched workloads.
