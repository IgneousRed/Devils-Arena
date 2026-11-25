#+test
#+private file
package headless

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:testing"

// ---------------- Project ----------------

import "../../src/catalog"
import "../../src/engine"
import "../../src/functions"
import "../../src/procedures"

// -------------------------------- Procedures --------------------------------

// ---------------- File ----------------

@(test)
replay_and_common_scaling :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	replay := example()
	bytes, err := json.marshal(replay, allocator = context.temp_allocator)
	decoded: Replay
	testing.expect(t, err == nil && functions.decode_json(bytes, &decoded, MAX_REPLAY_BYTES))
	first, ticks, ok := run(&decoded)
	testing.expect(t, ok && ticks > 0 && ticks <= catalog.BATTLE_TICKS && first.battle.phase != .Active)
	second, second_ticks, second_ok := run(&decoded)
	testing.expect(t, second_ok && first == second && ticks == second_ticks, "Identical replays reproduce complete facts")
	direct := decoded.initial.facts
	for step in decoded.steps {for _ in 0..<step.ticks {procedures.battle_tick(&direct, step.inputs)}}
	testing.expect(t, first == direct, "Headless and application combat use the same simulation")
	scaled, scaled_ticks, scaled_ok := run(&decoded, 7)
	testing.expect(t, scaled_ok && scaled_ticks == ticks && scaled.battle == first.battle)
	for combatant, id in first.combatants {
		testing.expect(t, abs(scaled.combatants[id].health - combatant.health * 7) < 1e-8)
		testing.expect_value(t, scaled.bodies[id].x, first.bodies[id].x)
	}
	testing.expect(t, decoded.initial.facts == replay.initial.facts, "Running does not alter the replay's initial state")

	impulses := example()
	impulses.steps[0] = {ticks = 1}
	for &c in impulses.initial.facts.combatants {c.health = 1e10; c.armor = 1e10; c.reflex = 0}
	for &spell in impulses.initial.facts.spells {spell = {spell = .Meteor, x = 140, remaining = 0.185}}
	pushed, pushed_ticks, pushed_ok := run(&impulses)
	testing.expect(t, pushed_ok && pushed_ticks == 1 && pushed.bodies[1].vx == 13440,
		"Simultaneous impulses must commit even when velocity exceeds the world-coordinate bound")
	impulses = example()
	impulses.steps[0] = {ticks = 1}
	impulses.initial.facts.bodies[0].vx = max(f64)
	pushed, pushed_ticks, pushed_ok = run(&impulses)
	testing.expect(t, pushed_ok && pushed_ticks == 1 && pushed.bodies[0].vx < max(f64),
		"Drag must preserve finite velocities without an overflowing intermediate")

	// Splitting a replay at a step boundary must also preserve in-flight spells and cooldowns.
	replay.steps[0].ticks = 10
	middle, middle_ticks, middle_ok := run(&replay)
	testing.expect(t, middle_ok && middle_ticks == 10 && middle.battle.phase == .Active)
	replay.initial.facts = middle
	replay.steps[0].ticks = 20
	resumed, resumed_ticks, resumed_ok := run(&replay)
	replay = example()
	replay.steps[0].ticks = 30
	whole, _, whole_ok := run(&replay)
	testing.expect(t, resumed_ok && resumed_ticks == 20 && whole_ok && resumed == whole)
	replay = example()
	replay.steps[0].ticks = 25
	trace := Trace{every = 10}
	traced, traced_ticks, traced_ok := run(&replay, trace = &trace)
	plain, plain_ticks, plain_ok := run(&replay)
	testing.expect(t, traced_ok && plain_ok && traced == plain && traced_ticks == plain_ticks,
		"Tracing must not change simulation outcomes")
	testing.expect_value(t, len(trace.snapshots), 4)
	for expected, index in ([4]u32{0, 10, 20, 25}) {
		testing.expect(t, trace.snapshots[index].version == replay.initial.version && trace.snapshots[index].facts.battle.ticks == expected,
			"Trace includes the initial state, Tick intervals, and an unsampled final state exactly once")
		encoded, encoded_ok := functions.encode_save(trace.snapshots[index].facts)
		decoded, decoded_ok := functions.decode_save(encoded)
		testing.expect(t, encoded_ok && decoded_ok && decoded == trace.snapshots[index], "Trace entries are complete player saves")
	}
	testing.expect_value(t, trace.snapshots[0], replay.initial)
	testing.expect_value(t, trace.snapshots[3].facts, traced)
	replay.initial = trace.snapshots[2]
	replay.steps[0].ticks = 5
	continued, _, continued_ok := run(&replay)
	testing.expect(t, continued_ok && continued == traced, "A trace snapshot can resume the same replay trajectory")
	trace.every = 5
	replay.steps[0].ticks = 10
	_, _, aligned_ok := run(&replay, trace = &trace)
	testing.expect(t, aligned_ok && len(trace.snapshots) == 3 && trace.snapshots[0].facts.battle.ticks == 20 &&
		trace.snapshots[1].facts.battle.ticks == 25 && trace.snapshots[2].facts.battle.ticks == 30,
		"Sampling counts from the resumed initial state and does not duplicate an aligned final snapshot")

	replay = example()
	replay.initial.facts.combatants[1].health = 1e-7
	replay.initial.facts.combatants[1].armor = 0
	replay.initial.facts.bodies[1].x = catalog.ARENA_RADIUS + 1
	trace.every = 100
	terminal, terminal_ticks, terminal_ok := run(&replay, trace = &trace)
	testing.expect(t, terminal_ok && terminal_ticks == 1 && terminal.battle.phase == .Player_Won)
	testing.expect(t, len(trace.snapshots) == 2 && trace.snapshots[1].facts == terminal,
		"Early defeat forces a final snapshot and each run replaces the previous trace")
	encoded_plain, plain_error := json.marshal(Result{}, allocator = context.temp_allocator)
	expected_result := Result{seed = terminal.battle.seed, repetitions = 1, simulated_ticks = u64(terminal_ticks),
		final = trace.snapshots[1], trace = trace.snapshots[:]}
	encoded_trace, trace_error := json.marshal(expected_result, allocator = context.temp_allocator)
	testing.expect(t, plain_error == nil && trace_error == nil && !strings.contains(string(encoded_plain), "\"trace\"") &&
		strings.contains(string(encoded_trace), "\"trace\""), "Default result JSON remains unchanged unless tracing is requested")
	decoded_result: Result
	result_ok := functions.decode_json(encoded_trace, &decoded_result, MAX_REPLAY_BYTES)
	testing.expect(t, result_ok && decoded_result.seed == expected_result.seed && decoded_result.repetitions == 1 &&
		decoded_result.simulated_ticks == 1 && decoded_result.final == expected_result.final &&
		len(decoded_result.trace) == 2 && decoded_result.trace[0] == trace.snapshots[0] && decoded_result.trace[1] == trace.snapshots[1],
		"Complete trace results, including 64-bit counters, must survive strict decoding")
	before_invalid := engine.begin().data
	for interval in ([2]u32{0, catalog.BATTLE_TICKS + 1}) {
		invalid_trace := Trace{every = interval}
		_, _, accepted := run(&replay, trace = &invalid_trace)
		testing.expect(t, !accepted && engine.begin().data == before_invalid, "Reject invalid trace intervals before changing live facts")
	}

	wrong_build := decoded
	wrong_build.build = "another-version"
	wrong_bytes, wrong_err := json.marshal(wrong_build, allocator = context.temp_allocator)
	rejected_build: Replay
	testing.expect(t, wrong_err == nil && !decode_replay(wrong_bytes, &rejected_build))
	_, _, wrong_ok := run(&wrong_build)
	testing.expect(t, !wrong_ok, "Other application versions are rejected, including in-memory replays")

	wrong_format := decoded
	wrong_format.version = 2
	old_bytes, old_err := json.marshal(wrong_format, allocator = context.temp_allocator)
	testing.expect(t, old_err == nil && !decode_replay(old_bytes, &rejected_build), "Older replay formats are not migrated")

	// Keep engine-using checks in one test: the live store has one writer.
	replay = example()
	_, _, ok = run(&replay)
	testing.expect(t, ok)
	before := engine.begin().data
	bytes, err = json.marshal(replay, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	for replacement in ([5][2]string{
		{"\"version\":3", "\"version\":4294967296"},
		{"\"seed\":1", "\"seed\":-1"},
		{"\"casts\":2", "\"casts\":128"},
		{"\"steps\":[", "\"steps\":null,\"extra\":["},
		{"\"ticks\":6000", "\"ticks\":-1"},
	}) {
		invalid, _ := strings.replace_all(string(bytes), replacement[0], replacement[1], context.temp_allocator)
		rejected: Replay
		testing.expect(t, invalid != string(bytes) && !functions.decode_json(transmute([]u8)invalid, &rejected, MAX_REPLAY_BYTES))
	}
	replay.steps[0].ticks = catalog.BATTLE_TICKS + 1
	_, _, ok = run(&replay)
	testing.expect(t, !ok && engine.begin().data == before)
	replay = example()
	replay.steps[0].inputs[1].move_x = math.inf_f64(1)
	_, _, ok = run(&replay)
	testing.expect(t, !ok && engine.begin().data == before)
	replay = example()
	replay.initial.facts.items[1][0] = .Fireball
	_, _, ok = run(&replay)
	testing.expect(t, !ok && engine.begin().data == before, "Initial state must pass the normal ownership constraints")
	replay = example()
	_, _, ok = run(&replay, 0)
	testing.expect(t, !ok && engine.begin().data == before)
	replay.initial.version += 1
	_, _, ok = run(&replay)
	testing.expect(t, !ok && engine.begin().data == before)
}
