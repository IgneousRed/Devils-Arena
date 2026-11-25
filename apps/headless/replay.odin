#+private
package headless

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:math"

// ---------------- Project ----------------

import "../../src/catalog"
import "../../src/engine"
import "../../src/functions"
import "../../src/procedures"
import "../../src/state"

// -------------------------------- Constants --------------------------------

// ---------------- Package ----------------

MAX_REPLAY_BYTES :: 4 * 1024 * 1024

// ---------------- File ----------------

@(private = "file")
REPLAY_VERSION :: u32(3)

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

// Inputs use arena-space aim points. Each step holds both players' inputs for its Ticks.
Replay :: struct {
	version: u32,
	build: string,
	initial: state.Save_File,
	steps: []Step,
}

// ---------------- File ----------------

@(private = "file")
Step :: struct {ticks: u32, inputs: [catalog.COMBATANT_COUNT]state.Battle_Input}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

decode_replay :: proc(bytes: []u8, output: ^Replay) -> bool {
	current: Replay
	if state.APPLICATION_VERSION == "unversioned" {return false}
	if !functions.decode_json(bytes, &current, MAX_REPLAY_BYTES) || current.version != REPLAY_VERSION ||
	   current.build != state.APPLICATION_VERSION || current.initial.version != state.SAVE_VERSION {return false}
	output^ = current
	return true
}

run :: proc(replay: ^Replay, scale := f64(1), trace: ^Trace = nil) -> (facts: state.Facts, ticks: u32, ok: bool) {
	if state.APPLICATION_VERSION == "unversioned" || replay.version != REPLAY_VERSION || replay.build != state.APPLICATION_VERSION || replay.initial.version != state.SAVE_VERSION ||
	   replay.initial.facts.battle.phase != .Active || scale <= 0 || math.is_nan(scale) || math.is_inf(scale) {return}
	if trace != nil && (trace.every == 0 || trace.every > catalog.BATTLE_TICKS) {return}
	planned: u32
	for step in replay.steps {
		if step.ticks == 0 || step.ticks > catalog.BATTLE_TICKS - planned {return}
		planned += step.ticks
		for input in step.inputs {
			if input.casts - {.Fireball, .Lightning, .Meteor, .Teleport, .Swap} != {} {return}
			for value in ([4]f64{input.move_x, input.move_y, input.aim_x, input.aim_y}) {
				if math.is_nan(value) || math.is_inf(value) {return}
			}
		}
	}
	if planned == 0 {return}
	tx := engine.begin()
	tx.data = {facts = replay.initial.facts}
	for &combatant in tx.data.facts.combatants {
		combatant.health *= scale
		combatant.armor *= scale
		combatant.reflex *= scale
		combatant.mastery *= scale
		combatant.speed *= scale
		combatant.power *= scale
	}
	for &body in tx.data.facts.bodies {body.starting_health *= scale}
	if !engine.commit(&tx) {return}
	if trace != nil {
		trace.snapshots = make([dynamic]state.Save_File, 0, int(planned / trace.every) + 2, context.temp_allocator)
		append(&trace.snapshots, state.Save_File{version = state.SAVE_VERSION, facts = tx.data.facts})
	}
	for step in replay.steps {
		for _ in 0..<step.ticks {
			if tx.data.facts.battle.phase != .Active {return tx.data.facts, ticks, true}
			if !procedures.battle_tick(&tx.data.facts, step.inputs) {return}
			if !engine.commit(&tx) {return}
			ticks += 1
			if trace != nil && (ticks % trace.every == 0 || ticks == planned || tx.data.facts.battle.phase != .Active) {
				append(&trace.snapshots, state.Save_File{version = state.SAVE_VERSION, facts = tx.data.facts})
			}
		}
	}
	return tx.data.facts, ticks, true
}

// An explicit inspection fixture, not an inventory-selection policy for self-play.
example :: proc() -> Replay {
	facts: state.Facts
	facts.items[0][0] = .Fireball
	facts.items[1][0] = .Lightning
	procedures.start_battle(&facts)
	steps := make([]Step, 1, context.temp_allocator)
	steps[0] = {ticks = catalog.BATTLE_TICKS, inputs = {{casts = {.Fireball}, aim_x = 170}, {casts = {.Lightning}, aim_x = -170}}}
	return {version = REPLAY_VERSION, build = state.APPLICATION_VERSION, initial = {version = state.SAVE_VERSION, facts = facts}, steps = steps}
}
