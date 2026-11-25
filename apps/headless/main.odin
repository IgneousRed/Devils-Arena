package headless

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"

// ---------------- Project ----------------

import "../../src/catalog"
import "../../src/state"

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

@(private = "package")
Result :: struct {
	seed: u32,
	repetitions, simulated_ticks: u64,
	final: state.Save_File,
	trace: []state.Save_File `json:"trace,omitempty"`,
}

// Optional inspection output, owned by context.temp_allocator for one run.
@(private = "package")
Trace :: struct {every: u32, snapshots: [dynamic]state.Save_File}

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

main :: proc() {
	defer free_all(context.temp_allocator)
	if len(os.args) == 2 && os.args[1] == "--example" {
		bytes, err := json.marshal(example(), allocator = context.temp_allocator)
		if err != nil {fail("Could not encode example replay")}
		fmt.println(string(bytes))
		return
	}
	if len(os.args) < 2 || len(os.args) % 2 != 0 {
		fail("Usage: scripts/headless.sh replay.json [--scale factor] [--repeat count] [--trace-every ticks] [--seed value] | --example")
	}
	scale := f64(1)
	repetitions := u64(1)
	seed: u32
	seed_override := false
	trace: Trace
	for i := 2; i < len(os.args); i += 2 {
		switch os.args[i] {
		case "--scale":
			value, ok := strconv.parse_f64(os.args[i + 1])
			if !ok || value <= 0 || math.is_nan(value) || math.is_inf(value) {fail("Scale must be finite and positive")}
			scale = value
		case "--repeat":
			value, ok := strconv.parse_u64(os.args[i + 1])
			if !ok || value == 0 {fail("Repeat count must be a positive integer")}
			repetitions = value
		case "--trace-every":
			value, ok := strconv.parse_u64(os.args[i + 1])
			if !ok || value == 0 || value > u64(catalog.BATTLE_TICKS) {fail("Trace interval must be an integer from 1 to 6000 Ticks")}
			trace.every = u32(value)
		case "--seed":
			value, ok := strconv.parse_u64(os.args[i + 1])
			if !ok || value > u64(max(u32)) {fail("Seed must be an unsigned 32-bit integer")}
			seed, seed_override = u32(value), true
		case:
			fail(fmt.tprintf("Unknown option: %s", os.args[i]))
		}
	}
	file, open_error := os.open(os.args[1])
	if open_error != nil {fail("Could not open replay")}
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil || size <= 0 || size > MAX_REPLAY_BYTES {fail("Replay must contain at most 4 MiB of JSON")}
	bytes := make([]u8, int(size), context.temp_allocator)
	count, read_error := os.read_full(file, bytes)
	if read_error != nil || count != len(bytes) {fail("Could not read replay")}
	replay: Replay
	if !decode_replay(bytes, &replay) {fail("Invalid replay JSON")}
	if seed_override {replay.initial.facts.battle.seed = seed}
	result := Result{seed = replay.initial.facts.battle.seed, repetitions = repetitions}
	for repetition in 0..<repetitions {
		// Identical repetitions need only one trajectory; keep memory independent of --repeat.
		captured: ^Trace
		if trace.every > 0 && repetition == repetitions - 1 {captured = &trace}
		facts, ticks, ok := run(&replay, scale, captured)
		if !ok {fail("Invalid replay/state, undefined zero-stat ratio, or rejected simulation transaction")}
		result.simulated_ticks += u64(ticks)
		result.final = {version = state.SAVE_VERSION, facts = facts}
	}
	result.trace = trace.snapshots[:]
	output, err := json.marshal(result, allocator = context.temp_allocator)
	if err != nil {fail("Could not encode simulation result")}
	fmt.println(string(output))
}

// ---------------- File ----------------

@(private = "file")
fail :: proc(message: string) -> ! {
	fmt.eprintln(message)
	os.exit(1)
}
