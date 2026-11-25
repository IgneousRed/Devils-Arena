package tests

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:encoding/json"
import "core:math"
import "core:strings"
import "core:testing"

// ---------------- Project ----------------

import "../src/catalog"
import "../src/effects"
import "../src/engine"
import "../src/functions"
import "../src/migrations"
import "../src/procedures"
import "../src/state"

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

@(test)
lightning_reaches_opposite_world_corners :: proc(t: ^testing.T) {
	for owner in 0..<catalog.COMBATANT_COUNT {
		for side in ([2]f64{-1, 1}) {
			facts := training_battle()
			if owner == 1 {facts.items[1], facts.items[0] = facts.items[0], {}}
			facts.bodies[owner].x, facts.bodies[owner].y = -catalog.WORLD_LIMIT, side * catalog.WORLD_LIMIT
			facts.bodies[1 - owner].x, facts.bodies[1 - owner].y = catalog.WORLD_LIMIT, -side * catalog.WORLD_LIMIT
			control := facts
			inputs: [catalog.COMBATANT_COUNT]state.Battle_Input
			inputs[owner] = {casts = {.Lightning}, aim_x = facts.bodies[1 - owner].x, aim_y = facts.bodies[1 - owner].y}
			testing.expect(t, procedures.battle_tick(&control, {}) && procedures.battle_tick(&facts, inputs))
			testing.expect(t, abs(control.combatants[1 - owner].health - facts.combatants[1 - owner].health - 20) < 1e-10,
				"A straight Lightning strike must cover the world diagonal as well as its axes")
		}
	}
}

@(test)
damage_preserves_small_proportional_losses :: proc(t: ^testing.T) {
	for armor in ([2]f64{1e-300, 1e-15}) {
		hp_loss, armor_loss := functions.armor_damage({health = 1e308, armor = armor}, 2e307)
		testing.expect(t, hp_loss == 2e307 && abs(armor_loss / (armor * 0.2) - 1) < 1e-12,
			"An underflowing or subnormal share must not erase a representable Armor loss")
		hp_loss, armor_loss = functions.armor_damage({health = armor, armor = 1e308}, 1e308)
		testing.expect(t, hp_loss == 0 && abs(armor_loss / armor - 1) < 1e-12,
			"Weight damage before a tiny HP share loses its magnitude")
	}
	tiny := f64(0h0000000000000001)
	hp_loss, armor_loss := functions.armor_damage({health = tiny, armor = 1e-15}, 1e308)
	reduced := tiny * 1e308 / 1e-15
	testing.expect(t, abs(armor_loss / reduced - 1) < 1e-12 && abs(hp_loss / ((reduced / 1e-15) * tiny) - 1) < 1e-12,
		"Reordering must not introduce overflow when the large stat is itself small")
	facts := training_battle()
	facts.combatants[1].health, facts.combatants[1].armor = 1e308, 1e-300
	facts.bodies[1].starting_health = 1e308
	testing.expect(t, procedures.battle_tick(&facts, {{casts = {.Lightning}, aim_x = 170}, {}}))
	testing.expect(t, abs(facts.combatants[1].armor / 8e-301 - 1) < 1e-12,
		"The committed combat result must preserve the small Armor loss")
}

@(test)
cursor_direction_survives_world_bounds :: proc(t: ^testing.T) {
	for owner in 0..<catalog.COMBATANT_COUNT {
		for side in ([2]f64{-1, 1}) {
			for spell in catalog.Spell.Fireball..=catalog.Spell.Swap {
				facts := training_battle()
				if owner == 1 {facts.items[1], facts.items[0] = facts.items[0], {}}
				facts.bodies[owner].x = side * catalog.WORLD_LIMIT
				facts.bodies[1 - owner].x = 0
				inputs: [catalog.COMBATANT_COUNT]state.Battle_Input
				inputs[owner] = {casts = {spell}, aim_x = side * (catalog.WORLD_LIMIT + 100)}
				testing.expect(t, procedures.battle_tick(&facts, inputs))
				switch spell {
				case .Fireball, .Swap, .Lightning:
					testing.expect(t, facts.spells[0].vx * side > 0 && facts.spells[0].vy == 0,
						"An outward cursor must not redirect a spell toward the opponent")
				case .Meteor:
					testing.expect(t, facts.spells[0].x == side * catalog.WORLD_LIMIT,
						"Ground targets remain bounded without invoking the zero-aim fallback")
				case .Teleport:
					testing.expect(t, facts.bodies[owner].x == side * catalog.WORLD_LIMIT,
						"An outward blink at the boundary must not move toward the opponent")
				case .None:
				}
			}
		}
	}
	facts := training_battle()
	facts.bodies[0].x = 500
	procedures.battle_tick(&facts, {{casts = {.Fireball, .Lightning, .Teleport}, aim_x = 800, aim_y = 400}, {}})
	testing.expect(t, abs(facts.spells[0].vx / catalog.SPELLS[.Fireball].projectile_speed - 0.6) < 1e-12 &&
		abs(facts.spells[0].vy / catalog.SPELLS[.Fireball].projectile_speed - 0.8) < 1e-12,
		"Clipping a destination must not bend the cursor's direction")
	beam_x, beam_y := functions.direction(facts.spells[1].vx, facts.spells[1].vy)
	testing.expect(t, abs(beam_x - 0.6) < 1e-12 && abs(beam_y - 0.8) < 1e-12)
	testing.expect(t, facts.bodies[0].x == catalog.WORLD_LIMIT && abs(facts.bodies[0].y - 192) < 1e-12,
		"Teleport follows the cursor for its range before the resulting position is bounded")

	for magnitude in ([2]f64{max(f64), 1e-300}) {
		dx, dy := functions.direction(magnitude, -magnitude)
		testing.expect(t, abs(dx - math.sqrt(0.5)) < 1e-12 && abs(dy + math.sqrt(0.5)) < 1e-12,
			"Finite direction vectors must survive squared-length overflow and underflow")
	}
	facts = training_battle()
	procedures.battle_tick(&facts, {{casts = {.Fireball, .Teleport}, aim_x = max(f64), aim_y = max(f64)}, {}})
	testing.expect(t, facts.spells[0].vx > 0 && facts.spells[0].vy > 0 &&
		abs(facts.bodies[0].x - (-170 + 240 * math.sqrt(0.5))) < 1e-12 &&
		abs(facts.bodies[0].y - 240 * math.sqrt(0.5)) < 1e-12,
		"Large finite headless aim points preserve direction and the Teleport range")
}



@(test)
strict_integer_destination_boundaries :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for expected in ([5]i64{min(i64), -1, 0, 1, max(i64)}) {
		bytes, err := json.marshal(expected, allocator = context.temp_allocator)
		actual: i64
		testing.expect(t, err == nil && functions.decode_json(bytes, &actual) && actual == expected,
			"Every signed 64-bit integer in the parser's range must decode without narrowing")
	}
	for expected in ([3]u64{0, 1, u64(max(i64))}) {
		bytes, err := json.marshal(expected, allocator = context.temp_allocator)
		actual: u64
		testing.expect(t, err == nil && functions.decode_json(bytes, &actual) && actual == expected,
			"Unsigned destinations must accept nonnegative integers within the signed parser's range")
	}
	for text in ([3]string{"-1", "9223372036854775808", "18446744073709551615"}) {
		actual: u64
		testing.expect(t, !functions.decode_json(transmute([]u8)text, &actual),
			"Unsigned destinations must not bypass the parser's literal-range guard")
	}
	signed: i8
	unsigned: u8
	testing.expect(t, functions.decode_json(transmute([]u8)string("-128"), &signed) && signed == min(i8))
	testing.expect(t, functions.decode_json(transmute([]u8)string("127"), &signed) && signed == max(i8))
	testing.expect(t, functions.decode_json(transmute([]u8)string("255"), &unsigned) && unsigned == max(u8))
	for text in ([2]string{"-129", "128"}) {testing.expect(t, !functions.decode_json(transmute([]u8)text, &signed))}
	for text in ([2]string{"-1", "256"}) {testing.expect(t, !functions.decode_json(transmute([]u8)text, &unsigned))}
}


@(test)
combat_readouts_follow_selected_player_and_shared_formulas :: proc(t: ^testing.T) {
	facts: state.Facts
	empty := functions.overview(facts, {})
	testing.expect(t, !empty.critical_defined && !empty.dodge_defined && !empty.cooldown_defined,
		"Undefined zero-stat ratios must not be presented as probabilities or cooldown rates")
	facts.combatants = {{mastery = 300, reflex = 100, speed = 100}, {mastery = 100, reflex = 100, speed = 200}}
	before := facts
	player := functions.overview(facts, {})
	opponent := functions.overview(facts, {selected = 1})
	testing.expect(t, player.critical_defined && player.dodge_defined && player.cooldown_defined)
	testing.expect(t, player.critical_chance == 0.75 && player.dodge_chance == 0.5 && player.cooldown_rate == 0.5)
	testing.expect(t, opponent.critical_chance == 0.5 && opponent.dodge_chance == 0.25 && opponent.cooldown_rate == 1,
		"Selection must reverse the own/opponent stat pairing")
	testing.expect(t, facts == before, "Queries cannot change authoritative facts")
	for &c in facts.combatants {c.mastery *= 7; c.reflex *= 7; c.speed *= 7}
	scaled := functions.overview(facts, {})
	testing.expect(t, scaled.critical_chance == player.critical_chance && scaled.dodge_chance == player.dodge_chance &&
		scaled.cooldown_rate == player.cooldown_rate, "Readouts must preserve common stat scaling")
	for &c in facts.combatants {c.mastery = max(f64); c.reflex = max(f64); c.speed = max(f64)}
	large := functions.overview(facts, {})
	testing.expect(t, large.critical_chance == 0.5 && large.dodge_chance == 0.5 && large.cooldown_rate == 1,
		"Finite large stats must not overflow the displayed probabilities")
	facts = {}
	facts.combatants[1] = {mastery = 100, speed = 100}
	zero := functions.overview(facts, {})
	testing.expect(t, !zero.critical_defined && zero.dodge_defined && zero.dodge_chance == 0 &&
		zero.cooldown_defined && zero.cooldown_rate == 0,
		"A defined zero rate must remain distinct from an undefined 0/0")
}

@(test)
interrupted_recording_retains_complete_prefix :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	event, err := json.marshal(state.Recording_Event{}, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	header := "header\n"
	for suffix, index in ([6]string{"", "\n", "\n{\"kind\":", "\n{\"final\":", "\ninvalid\n", "\ninvalid\n  "}) {
		bytes := transmute([]u8)strings.concatenate({header, string(event), suffix}, context.temp_allocator)
		lines := functions.recording_lines(bytes)
		testing.expect_value(t, len(lines), 3 if index >= 4 else 1)
		if index >= 4 {testing.expect(t, lines[2] == "invalid", "Malformed complete records must remain visible to replay validation")}
		delete(lines)
	}
	storage, storage_err := json.marshal(state.Recording_Event{kind = .Storage}, allocator = context.temp_allocator)
	testing.expect(t, storage_err == nil)
	for suffix in ([2]string{"", "\n"}) {
		lines := functions.recording_lines(transmute([]u8)strings.concatenate({header, string(event), "\n", string(storage), suffix}, context.temp_allocator))
		testing.expect_value(t, len(lines), 3)
		testing.expect_value(t, lines[1], string(event))
		testing.expect(t, lines[2] == string(storage), "A recorded storage failure is a known response, unlike a missing result")
		delete(lines)
	}
	footer, footer_err := json.marshal(state.Recording_End{}, allocator = context.temp_allocator)
	testing.expect(t, footer_err == nil)
	lines := functions.recording_lines(transmute([]u8)strings.concatenate({header, string(event), "\n", string(footer)}, context.temp_allocator))
	testing.expect_value(t, len(lines), 3)
	testing.expect_value(t, lines[1], string(event))
	testing.expect(t, lines[2] == string(footer), "A complete footer does not require a trailing newline")
	delete(lines)
}

@(test)
recorded_boundary_values :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	frame := state.Frame_Input{width = 1920, height = 1600, pixel_ratio = 2, seconds = 0.017, focused = true,
		mouse_x = 333.5, mouse_y = 91, keys = {.W, .S, .Left_Alt}, load_pressed = true}
	event := state.Recording_Event{kind = .Frame, frame = frame, storage = {bytes = []u8{0, 255, 128, 34, 10}, read_ok = true}}
	bytes, err := json.marshal(event, allocator = context.temp_allocator)
	decoded: state.Recording_Event
	testing.expect(t, err == nil && functions.decode_json(bytes, &decoded, len(bytes)))
	testing.expect(t, decoded.frame == frame && decoded.storage.read_ok && len(decoded.storage.bytes) == 5)
	for value, index in event.storage.bytes {testing.expect(t, decoded.storage.bytes[index] == value)}
	testing.expect(t, functions.valid_frame_input(frame))
	for bad in ([3]state.Frame_Input{{width = 1, height = 1}, {width = 1, height = 1, pixel_ratio = 1, seconds = -1},
		{width = 1, height = 1, pixel_ratio = 1, seconds = math.inf_f64(1)}}) {
		testing.expect(t, !functions.valid_frame_input(bad))
	}
	bad_bool, _ := strings.replace_all(string(bytes), "\"read_ok\":true", "\"read_ok\":1", context.temp_allocator)
	testing.expect(t, !functions.decode_json(transmute([]u8)bad_bool, &decoded, len(bad_bool)))
}

@(test)
frozen_legacy_snapshots :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for bytes, index in ([2][]u8{#load("fixtures/reload-v1.json", []u8), #load("fixtures/reload-v2.json", []u8)}) {
		snapshot, ok := functions.decode_reload(bytes)
		testing.expect(t, ok && snapshot.version == state.RELOAD_VERSION)
		testing.expect_value(t, snapshot.data.facts.combatants[0], state.Combatant{42.75, 15, 8, 7, 100, 100})
		testing.expect(t, snapshot.data.ui == state.UI{1, 22} && snapshot.data.notice == .Saved)
		testing.expect(t, snapshot.data.facts.session == state.Session{12, 2})
		if index == 1 {
			testing.expect(t, snapshot.data.facts.battle.phase == .Active && snapshot.data.facts.battle.ticks == 1750)
			testing.expect(t, snapshot.data.facts.items[0][0] == .Meteor && snapshot.data.facts.cooldowns[0][0] == 1.25)
			testing.expect(t, snapshot.data.facts.spells[0].spell == .Meteor && snapshot.data.facts.spells[0].remaining == 0.5)
		}
	}
}

@(test)
expired_effects_and_saturated_casts :: proc(t: ^testing.T) {
	facts := training_battle()
	facts.spells[0] = {spell = .Fireball, x = 140, vx = 560}
	procedures.battle_tick(&facts, {})
	testing.expect(t, facts.combatants[1].health == 100 && facts.spells[0].spell == .None,
		"An already-expired projectile cannot deal one last hit")

	facts = training_battle()
	for &spell in facts.spells {spell = {spell = .Fireball, x = -500, y = 500, remaining = 1}}
	swapped := facts
	swapped.items[0][0], swapped.items[0][3] = swapped.items[0][3], swapped.items[0][0]
	input := state.Battle_Input{casts = {.Fireball, .Lightning, .Teleport}, aim_x = 170}
	procedures.battle_tick(&facts, {input, {}})
	procedures.battle_tick(&swapped, {input, {}})
	testing.expect(t, facts.bodies[0].x == 70 && facts.combatants[1].health == 80,
		"Full cosmetic capacity cannot block Teleport or Lightning gameplay")
	testing.expect(t, facts.bodies == swapped.bodies && facts.combatants == swapped.combatants,
		"Inventory order cannot choose which instant spells activate")
	testing.expect(t, facts.cooldowns[0][0] == 0 && facts.cooldowns[0][1] > 0 && facts.cooldowns[0][3] > 0,
		"Only successful activations consume cooldowns")

	facts = training_battle()
	for &spell in facts.spells {spell = {spell = .Lightning, remaining = 0.16}}
	procedures.battle_tick(&facts, {{casts = {.Fireball}, aim_x = 170}, {}})
	testing.expect(t, facts.spells[0].spell == .Fireball && facts.cooldowns[0][0] > 0,
		"Cosmetic occupancy cannot block a persistent gameplay effect")

	facts = training_battle()
	for &spell in facts.spells[:len(facts.spells) - 1] {spell = {spell = .Fireball, x = -500, y = 500, remaining = 1}}
	swapped = facts
	swapped.items[0][0], swapped.items[0][2] = swapped.items[0][2], swapped.items[0][0]
	input = {casts = {.Fireball, .Meteor}, aim_x = 170}
	procedures.battle_tick(&facts, {input, {}})
	procedures.battle_tick(&swapped, {input, {}})
	testing.expect(t, facts.spells == swapped.spells && facts.spells[len(facts.spells) - 1].spell == .Fireball,
		"Persistent overflow priority is independent of inventory display order")
}

@(test)
zero_aim_targets_opponent :: proc(t: ^testing.T) {
	for owner in 0..<catalog.COMBATANT_COUNT {
		for spell in catalog.Spell.Fireball..=catalog.Spell.Swap {
			facts := training_battle()
			if owner == 1 {facts.items[1], facts.items[0] = facts.items[0], {}}
			facts.bodies[1].x, facts.bodies[1].y = -300, 120
			explicit := facts
			caster, target := facts.bodies[owner], facts.bodies[1 - owner]
			inputs: [catalog.COMBATANT_COUNT]state.Battle_Input
			inputs[owner] = {casts = {spell}, aim_x = caster.x, aim_y = caster.y}
			testing.expect(t, procedures.battle_tick(&facts, inputs))
			inputs[owner].aim_x, inputs[owner].aim_y = target.x, target.y
			testing.expect(t, procedures.battle_tick(&explicit, inputs))
			testing.expect(t, facts == explicit, "Zero aim must match explicitly targeting the opponent for either player and every spell")
		}
	}
	facts := training_battle()
	facts.bodies[0].x, facts.bodies[1].x = 0, 0
	procedures.battle_tick(&facts, {{casts = {.Fireball}}, {}})
	procedures.battle_tick(&facts, {})
	testing.expect(t, facts.combatants[1].health < 100 && facts.bodies[1].vx == 0 && facts.bodies[1].vy == 0,
		"Overlapping opponents remain the target without inventing a direction")
}

@(test)
cooldown_reset_and_held_casts :: proc(t: ^testing.T) {
	facts := training_battle()
	seed := facts.battle.seed
	facts.bodies[0].lava_ticks = 20
	facts.combatants[0] = {health = 250, armor = 1, power = 0, speed = 0, reflex = 0, mastery = 0}
	procedures.start_battle(&facts)
	testing.expect(t, facts.combatants[0] == state.Combatant{100, 100, 100, 100, 100, 100})
	testing.expect(t, facts.battle.seed != seed && facts.bodies[0].lava_ticks == 0 && facts.battle.ticks == 0)
	for spell, slot in facts.items[0] {testing.expect_value(t, facts.cooldowns[0][slot], catalog.SPELLS[spell].cooldown)}
	input := state.Battle_Input{casts = {.Fireball, .Lightning, .Teleport}, aim_x = 170}
	procedures.battle_tick(&facts, {input, {}})
	testing.expect(t, facts.spells == ([catalog.EFFECT_LIMIT]state.Spell_Effect{}), "Full initial cooldowns prevent casting")

	facts = training_battle()
	facts.cooldowns[0][0] = 0.003
	procedures.battle_tick(&facts, {input, {}})
	testing.expect(t, abs(facts.cooldowns[0][0] - (catalog.SPELLS[.Fireball].cooldown - 0.007)) < 1e-12,
		"Held casts preserve cooldown overshoot")
	testing.expect(t, facts.spells[0].spell == .Fireball && facts.spells[1].spell == .Lightning && facts.spells[2].spell == .Teleport)
	testing.expect(t, facts.spells[0].x < -100 && facts.bodies[0].x == 70, "All cast origins precede Teleport")
	for _ in 0..<145 {procedures.battle_tick(&facts, {input, {}})}
	testing.expect(t, facts.cooldowns[0][0] > 1, "A held spell casts again when it becomes ready")

	facts = training_battle()
	facts.cooldowns[0][0] = 0.003
	procedures.battle_tick(&facts, {})
	testing.expect(t, facts.cooldowns[0][0] == 0 && facts.spells == ([catalog.EFFECT_LIMIT]state.Spell_Effect{}),
		"Readiness alone does not cast")
	facts = training_battle()
	facts.cooldowns[0][0] = 1
	facts.combatants[1].speed = 200
	procedures.battle_tick(&facts, {{move_x = 1}, {move_x = 1}})
	testing.expect(t, abs(facts.cooldowns[0][0] - 0.995) < 1e-12)
	testing.expect(t, abs((facts.bodies[0].x + 170) - (facts.bodies[1].x - 170)) < 1e-12,
		"The Speed stat does not change movement speed")
	facts.combatants[0].speed = 0
	before := facts.cooldowns[0]
	procedures.battle_tick(&facts, {})
	testing.expect_value(t, facts.cooldowns[0], before)
	facts.combatants[0].health = 250
	procedures.battle_tick(&facts, {})
	testing.expect_value(t, facts.combatants[0].health, f64(250))
}

@(test)
armor_critical_dodge_and_shared_effects :: proc(t: ^testing.T) {
	hp, armor := functions.armor_damage({health = 100, armor = 100}, 20)
	testing.expect(t, hp == 5 && armor == 5)
	testing.expect_value(t, functions.stat_share(max(f64), max(f64)), f64(0.5))
	hp, armor = functions.armor_damage({health = 1, armor = 1e20}, 1e60)
	testing.expect(t, abs(hp / 1e20 - 1) < 1e-12 && abs(armor / 1e40 - 1) < 1e-12,
		"Large Armor/HP ratios must not round nonzero damage away")
	hp, armor = functions.armor_damage({health = 1e20, armor = 1}, 1e60)
	testing.expect(t, abs(hp / 1e60 - 1) < 1e-12 && abs(armor / 1e40 - 1) < 1e-12,
		"Small Armor/HP ratios must retain the Armor share of damage")
	for critical in ([2]bool{false, true}) {for dodge in ([2]bool{false, true}) {
		facts := training_battle()
		for &c in facts.combatants {c.armor = 100; c.reflex = 100}
		found := false
		for seed in 0..<1000 {
			facts.battle.seed = u32(seed)
			outcomes, ok := procedures.battle_outcomes(&facts)
			if ok && outcomes.critical[0] == critical && outcomes.dodge[1] == dodge {found = true; break}
		}
		testing.expect(t, found, "Each independent critical/dodge combination must be reproducible")
		multiplier := f64(0) if dodge && !critical else f64(2) if critical && !dodge else f64(1)
		facts.spells[0] = {spell = .Fireball, x = 140, vx = 560, remaining = 1}
		initial := facts
		procedures.battle_tick(&facts, {{casts = {.Lightning, .Teleport}, aim_x = 170}, {}})
		testing.expect(t, abs(facts.combatants[1].health - (100 - 5.5 * multiplier)) < 1e-12,
			"Projectile and instant damage share this Tick's roll and starting Armor")
		testing.expect(t, abs(facts.combatants[1].armor - (100 - 5.5 * multiplier)) < 1e-12)
		testing.expect_value(t, facts.bodies[1].vx, f64(0) if multiplier == 0 else f64(600))
		testing.expect_value(t, facts.bodies[0].x, f64(70))

		facts = initial
		facts.spells[0].spell = .Swap
		procedures.battle_tick(&facts, {{casts = {.Teleport}, aim_x = 170}, {}})
		testing.expect_value(t, facts.bodies[0].x, f64(70) if multiplier == 0 else f64(410))
		testing.expect_value(t, facts.bodies[1].x, f64(170) if multiplier == 0 else f64(-170))
	}}
}

@(test)
shrinking_arena_lava_and_undefined_ratios :: proc(t: ^testing.T) {
	testing.expect_value(t, functions.arena_radius(0), f64(420))
	testing.expect_value(t, functions.arena_radius(3000), f64(210))
	testing.expect_value(t, functions.arena_radius(6000), f64(0))
	facts := training_battle()
	facts.combatants[0].armor = 100
	facts.bodies[0].x = 450
	procedures.battle_tick(&facts, {})
	testing.expect_value(t, facts.bodies[0].lava_ticks, u32(1))
	testing.expect(t, abs(facts.combatants[0].health - (100 - 0.25e-6)) < 1e-12,
		"Environmental damage uses Armor and ignores critical/dodge")
	procedures.battle_tick(&facts, {})
	testing.expect_value(t, facts.bodies[0].lava_ticks, u32(2))
	facts.bodies[0].x = 0
	health := facts.combatants[0].health
	procedures.battle_tick(&facts, {})
	testing.expect(t, facts.bodies[0].lava_ticks == 2 && facts.combatants[0].health == health)
	facts.bodies[0].x = 450
	hp_loss, _ := functions.armor_damage(facts.combatants[0], facts.bodies[0].starting_health * procedures.LAVA_SCALE * 9)
	procedures.battle_tick(&facts, {})
	testing.expect(t, facts.bodies[0].lava_ticks == 3 && abs(facts.combatants[0].health - (health - hp_loss)) < 1e-12)
	facts = training_battle()
	facts.battle.ticks = 3000
	facts.bodies[0].x = 300
	procedures.battle_tick(&facts, {})
	testing.expect_value(t, facts.bodies[0].lava_ticks, u32(1))

	facts = training_battle()
	for &c in facts.combatants {c.speed = 0}
	before := facts
	testing.expect(t, !procedures.battle_tick(&facts, {}) && facts == before,
		"An undefined ratio leaves the entire Tick untouched")
}

@(test)
simultaneous_actions_use_starting_values :: proc(t: ^testing.T) {
	facts := training_battle()
	// An incoming Swap and the player's Teleport both use (-170, 170) as their starting positions.
	facts.spells[0] = {spell = .Swap, owner = 1, x = -200, vx = 620, remaining = 1}
	procedures.battle_tick(&facts, {{casts = {.Teleport}, aim_x = 500}, {}})
	testing.expect_value(t, facts.bodies[0].x, f64(-170 + 340 + 240))
	testing.expect_value(t, facts.bodies[1].x, f64(-170))

	facts = training_battle()
	facts.items[0][1] = .None
	facts.items[1][0] = .Lightning
	facts.combatants[0].health = 10
	facts.combatants[1].health = 10
	procedures.battle_tick(&facts, {{casts = {.Fireball}, aim_x = 170}, {casts = {.Lightning}, aim_x = -170}})
	testing.expect_value(t, facts.combatants[0].health, f64(0))
	testing.expect_value(t, facts.spells[1].owner, u8(1))
	testing.expect(t, facts.spells[0].spell == .Fireball, "A lethal simultaneous attack does not prevent the other cast")

	facts = training_battle()
	facts.items[0][1] = .None
	facts.items[1][0] = .Lightning
	facts.spells[0] = {spell = .Fireball, x = 140, vx = 560, remaining = 1}
	facts.bodies[1].vx = 100
	procedures.battle_tick(&facts, {{}, {move_x = -1, casts = {.Lightning}, aim_x = -170}})
	testing.expect_value(t, facts.combatants[0].health, f64(80))
	testing.expect_value(t, facts.combatants[1].health, f64(76))
	testing.expect_value(t, facts.bodies[1].vx, f64(95 + 260))
	testing.expect_value(t, facts.bodies[1].x, f64(170 + (100 - 230) * catalog.TICK_SECONDS))

	facts = training_battle()
	facts.spells[0] = {spell = .Fireball, x = 140, vx = 560, remaining = 1}
	facts.spells[1] = {spell = .Meteor, x = 140, remaining = 0.185}
	reverse := facts
	reverse.spells[0], reverse.spells[1] = reverse.spells[1], reverse.spells[0]
	procedures.battle_tick(&facts, {})
	procedures.battle_tick(&reverse, {})
	testing.expect_value(t, facts.combatants, reverse.combatants)
	testing.expect_value(t, facts.bodies, reverse.bodies)
	testing.expect_value(t, facts.bodies[1].vx, f64(260 + 420))

	facts = training_battle()
	facts.items[0][1] = .None
	facts.items[1][0] = .Lightning
	facts.spells[0] = {spell = .Fireball, x = 140, vx = 560, remaining = 1}
	facts.combatants[0].health = 10
	facts.combatants[1].health = 10
	procedures.battle_tick(&facts, {{}, {casts = {.Lightning}, aim_x = -170}})
	testing.expect_value(t, facts.battle.phase, state.Battle_Phase.Draw)

	facts = training_battle()
	procedures.battle_tick(&facts, {{move_y = 1, casts = {.Fireball}, aim_x = 170}, {}})
	testing.expect(t, facts.spells[0].y == 0, "Casting reads the origin before movement")
	facts = training_battle()
	facts.bodies[0].x = catalog.ARENA_RADIUS + 1
	procedures.battle_tick(&facts, {{casts = {.Teleport}, aim_x = 0}, {}})
	testing.expect(t, facts.bodies[0].x < catalog.ARENA_RADIUS && facts.combatants[0].health < 100,
		"Teleport does not change the lava exposure sampled at the beginning of this Tick")
}

@(test)
spells_movement_and_damage :: proc(t: ^testing.T) {
	facts := training_battle()
	starting := facts
	procedures.battle_tick(&facts, {{move_x = 1, move_y = 1}, {}})
	dx, dy := facts.bodies[0].x - starting.bodies[0].x, facts.bodies[0].y - starting.bodies[0].y
	testing.expect(t, abs(math.sqrt(dx * dx + dy * dy) - catalog.MOVE_SPEED * catalog.TICK_SECONDS) < 1e-10)
	testing.expect(t, facts.bodies[1] == starting.bodies[1], "Dummy receives no movement input")

	facts = starting
	procedures.battle_tick(&facts, {{casts = {.Fireball}, aim_x = 170}, {}})
	for _ in 0..<70 {procedures.battle_tick(&facts, {{}, {}})}
	testing.expect(t, facts.combatants[1].health < 100 && facts.bodies[1].vx > 0, "Fireball damages and pushes")
	testing.expect(t, facts.cooldowns[0][0] > 0)
	before := facts.spells
	procedures.battle_tick(&facts, {{casts = {.Fireball}, aim_x = 170}, {}})
	count := 0
	for spell in before {if spell.spell != .None {count += 1}}
	after := 0
	for spell in facts.spells {if spell.spell != .None {after += 1}}
	testing.expect(t, after <= count, "Cooldown prevents another projectile")

	facts = starting
	procedures.battle_tick(&facts, {{casts = {.Lightning}, aim_x = 170}, {}})
	testing.expect(t, facts.combatants[1].health == 80 && facts.bodies[1].vx > 0)
	facts = starting
	procedures.battle_tick(&facts, {{casts = {.Lightning}, aim_x = -500, aim_y = 100}, {}})
	testing.expect(t, facts.combatants[1].health == f64(100), "Missed lightning does no damage")

	facts = starting
	procedures.battle_tick(&facts, {{casts = {.Meteor}, aim_x = 170}, {}})
	testing.expect(t, facts.combatants[1].health == f64(100), "Meteor has a warning delay")
	for _ in 0..<80 {procedures.battle_tick(&facts, {{}, {}})}
	testing.expect_value(t, facts.combatants[1].health, f64(52))

	facts = starting
	procedures.battle_tick(&facts, {{casts = {.Teleport}, aim_x = 500}, {}})
	testing.expect(t, facts.bodies[0].x == f64(70), "Teleport is range limited")
	facts = starting
	procedures.battle_tick(&facts, {{casts = {.Swap}, aim_x = 170}, {}})
	for _ in 0..<60 {procedures.battle_tick(&facts, {{}, {}})}
	testing.expect_value(t, facts.bodies[0].x, f64(170))
	testing.expect_value(t, facts.bodies[1].x, f64(-170))
	testing.expect_value(t, facts.combatants[1].health, f64(100))

	facts = starting
	facts.items = {}
	procedures.battle_tick(&facts, {{casts = {.Lightning}, aim_x = 170}, {}})
	testing.expect(t, facts.combatants[1].health == f64(100), "Unowned spells cannot be cast")
	testing.expect_value(t, facts.spells, starting.spells)
}

@(test)
reproducible_battle_end_and_reload :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	facts := training_battle()
	facts.bodies[1].x = catalog.ARENA_RADIUS + 1
	procedures.battle_tick(&facts, {{}, {}})
	testing.expect(t, facts.combatants[1].health < 100, "Lava drains HP outside the circle")
	facts.combatants[1].health = 1e-7
	procedures.battle_tick(&facts, {{}, {}})
	testing.expect_value(t, facts.battle.phase, state.Battle_Phase.Player_Won)
	finished := facts
	procedures.battle_tick(&facts, {{move_x = 1, casts = {.Lightning}}, {}})
	testing.expect(t, facts == finished, "Finished battles stop advancing")
	procedures.start_battle(&facts)
	testing.expect_value(t, facts.combatants[1].health, f64(100))
	testing.expect_value(t, facts.bodies[1].x, f64(170))
	facts.battle.ticks = catalog.BATTLE_TICKS - 1
	procedures.battle_tick(&facts, {{}, {}})
	testing.expect_value(t, facts.battle.phase, state.Battle_Phase.Draw)

	facts = training_battle()
	procedures.battle_tick(&facts, {{casts = {.Meteor}, aim_x = 170}, {}})
	bytes, encoded := functions.encode_reload({facts = facts})
	restored, decoded := functions.decode_reload(bytes)
	testing.expect(t, encoded && decoded)
	copy := restored.data.facts
	for tick in 0..<100 {
		input := state.Battle_Input{move_y = 0.25}
		if tick == 30 {input.casts = {.Fireball}; input.aim_x = 170}
		procedures.battle_tick(&facts, {input, {}})
		procedures.battle_tick(&copy, {input, {}})
	}
	testing.expect(t, copy == facts, "Mid-spell recovery reproduces the same subsequent battle")

	small := training_battle()
	large := small
	for &body in large.bodies {body.starting_health *= 7}
	for &combatant in large.combatants {combatant.health *= 7}
	for tick in 0..<1000 {
		input := state.Battle_Input{aim_x = 170}
		if tick % 150 == 0 {input.casts = {.Fireball}}
		procedures.battle_tick(&small, {input, {}})
		procedures.battle_tick(&large, {input, {}})
	}
	testing.expect_value(t, small.battle, large.battle)
	for c, id in small.combatants {
		testing.expect(t, abs(c.health * 7 - large.combatants[id].health) < 1e-8,
			"Common HP scaling preserves the battle trajectory and outcome")
		testing.expect_value(t, small.bodies[id].x, large.bodies[id].x)
	}

}

@(test)
v1_migration_preserves_facts_and_ui :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	old := migrations.Reload_V1{version = 1}
	old.data.facts.combatants[1] = {health = 42.75, armor = 15, agility = 6, speed = 7, power = 8}
	old.data.facts.activity[0] = {dodges = 9, misses = 2, move_progress = 0.5}
	old.data.facts.session = {kills = 12, speed_index = 2}
	old.data.ui = {selected = 1, scroll = 22}
	old.data.notice = .Saved
	bytes, err := json.marshal(old, allocator = context.temp_allocator)
	testing.expect(t, err == nil)
	migrated, ok := functions.decode_reload(bytes)
	testing.expect(t, ok && migrated.version == 3)
	testing.expect_value(t, migrated.data.facts.combatants[1].health, f64(42.75))
	testing.expect_value(t, migrated.data.facts.activity[0].dodges, u32(9))
	testing.expect_value(t, migrated.data.facts.session.kills, u32(12))
	testing.expect_value(t, migrated.data.ui.selected, i32(1))
	testing.expect_value(t, migrated.data.ui.scroll, f32(22))
	testing.expect_value(t, migrated.data.notice, state.Notice.Saved)
	testing.expect_value(t, migrated.data.facts.battle.phase, state.Battle_Phase.Picking)
	save, save_err := json.marshal(migrations.Save_V1{version = 1, facts = old.data.facts}, allocator = context.temp_allocator)
	file, loaded := functions.decode_save(save)
	testing.expect(t, save_err == nil && loaded)
	testing.expect_value(t, file.facts, migrated.data.facts)
}

@(test)
v2_migration_preserves_active_battle :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	old := migrations.Reload_V2{version = 2}
	for &c in old.data.facts.combatants {c = {health = 100, armor = 15, agility = 6, speed = 7, power = 8}}
	old.data.facts.bodies = {{x = -123, y = 24, vx = 4, starting_health = 200}, {x = 250, starting_health = 100}}
	old.data.facts.items[0][0] = .Meteor
	old.data.facts.cooldowns[0][0] = 1.25
	old.data.facts.spells[0] = {spell = .Meteor, x = 250, remaining = 0.5}
	old.data.facts.battle = {phase = .Active, ticks = 1750}
	old.data.ui = {selected = 1, scroll = 42}
	old.data.notice = .Saved
	bytes, err := json.marshal(old, allocator = context.temp_allocator)
	restored, ok := functions.decode_reload(bytes)
	testing.expect(t, err == nil && ok && restored.version == 3)
	facts := restored.data.facts
	testing.expect(t, facts.combatants[0] == state.Combatant{health = 100, armor = 15, power = 8, speed = 7, reflex = 100, mastery = 100})
	testing.expect(t, facts.bodies[0] == state.Body{x = -123, y = 24, vx = 4, starting_health = 200})
	expected_items: [catalog.COMBATANT_COUNT][catalog.ITEM_LIMIT]catalog.Spell
	expected_items[0][0] = .Meteor
	testing.expect(t, facts.items == expected_items && facts.cooldowns == old.data.facts.cooldowns)
	testing.expect(t, facts.spells[0].spell == .Meteor && facts.spells[0].remaining == 0.5)
	testing.expect(t, facts.battle.phase == .Active && facts.battle.ticks == 1750 && facts.battle.seed == 0)
	testing.expect(t, restored.data.ui.selected == 1 && restored.data.ui.scroll == 42 && restored.data.notice == .Saved)
	encoded, encoded_ok := functions.encode_reload(restored.data)
	current, current_ok := functions.decode_reload(encoded)
	testing.expect(t, encoded_ok && current_ok && current.data == restored.data)
	save, save_err := json.marshal(migrations.Save_V2{version = 2, facts = old.data.facts}, allocator = context.temp_allocator)
	loaded, loaded_ok := functions.decode_save(save)
	testing.expect(t, save_err == nil && loaded_ok && loaded.facts == facts)
	copy := current.data.facts
	for _ in 0..<100 {
		testing.expect(t, procedures.battle_tick(&facts, {}) && procedures.battle_tick(&copy, {}))
	}
	testing.expect_value(t, facts, copy)
}

@(test)
save_reload_and_reducer_boundaries :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tx := engine.begin()
	testing.expect(t, engine.commit(&tx), "Zero state must be valid")
	tx.data.facts.combatants[0] = {health = 123.75, armor = 1e100}
	tx.data.facts.activity[1] = {dodges = max(u32), move_progress = 0.5}
	tx.data.facts.session = {kills = max(u32), speed_index = 2}
	tx.data.ui = {selected = 1, scroll = 42.5}
	tx.data.notice = .Saved
	testing.expect(t, engine.commit(&tx))
	before := engine.begin().data
	view := functions.overview(before.facts, before.ui)
	testing.expect_value(t, view.simulation_speed, u8(4))
	testing.expect(t, engine.begin().data == before, "Derived queries must not mutate state")
	bytes, encoded := functions.encode_save(before.facts)
	testing.expect(t, encoded)
	file, decoded := functions.decode_save(bytes)
	testing.expect(t, decoded)
	testing.expect_value(t, file.facts, before.facts)
	for health in ([4]f64{1e19, 1e100, max(f64), -max(f64)}) {
		facts := before.facts
		facts.combatants[0].health = health
		encoded_facts, ok := functions.encode_save(facts)
		testing.expect(t, ok)
		decoded_facts, round_trip := functions.decode_save(encoded_facts)
		testing.expect(t, round_trip)
		testing.expect_value(t, decoded_facts.facts, facts)
	}
	next := engine.begin()
	procedures.stage_load(&next, file.facts)
	testing.expect(t, next.data.ui == state.UI{}, "Player saves do not contain development UI state")

	for replacement in ([7][2]string{
		{"\"version\":3", "\"version\":99"},
		{"\"version\":3", "\"version\":18446744073709551617"},
		{"4294967295", "4294967296"},
		{"4294967295", "18446744073709551616"},
		{"4294967295", "-1"},
		{"\"kills\":4294967295,", ""},
		{"123.75", "null"},
	}) {
		invalid, _ := strings.replace_all(string(bytes), replacement[0], replacement[1], context.temp_allocator)
		testing.expect(t, invalid != string(bytes), "Fixture must modify the encoded save")
		_, ok := functions.decode_save(transmute([]u8)invalid)
		testing.expect(t, !ok, "Reject incompatible or lossy saves")
	}
	_, partial := functions.decode_save(transmute([]u8)string(`{"version":1,"facts":{}}`))
	testing.expect(t, !partial)
	_, trailing := functions.decode_save(transmute([]u8)strings.concatenate({string(bytes), " {}"}, context.temp_allocator))
	testing.expect(t, !trailing)
	_, nul := functions.decode_save(transmute([]u8)strings.concatenate({string(bytes), "\x00discarded"}, context.temp_allocator))
	testing.expect(t, !nul, "A NUL byte must not hide trailing save data")
	deep := make([]u8, 16000, context.temp_allocator)
	for i in 0..<len(deep) / 2 {deep[i] = '['; deep[len(deep) - i - 1] = ']'}
	_, nested := functions.decode_save(deep)
	testing.expect(t, !nested, "Malformed nesting must be rejected without exhausting the stack")

	snapshot, snapshot_ok := functions.encode_reload(before)
	testing.expect(t, snapshot_ok)
	testing.expect(t, effects.execute({kind = .Reset}))
	testing.expect(t, engine.begin().data != before)
	testing.expect(t, effects.restore(snapshot))
	testing.expect(t, engine.begin().data == before, "Development restoration preserves all authoritative state")
	invalid := before
	invalid.facts.session.speed_index = 255
	rejected, _ := functions.encode_reload(invalid)
	testing.expect(t, !effects.restore(rejected))
	testing.expect(t, engine.begin().data == before, "Rejected restoration must not alter the live session")
	testing.expect(t, !effects.restore(transmute([]u8)string(`{"version":2}`)))
	testing.expect_value(t, engine.begin().data, before)
	testing.expect(t, effects.execute({kind = .Cycle_Speed}))
	testing.expect_value(t, engine.begin().data.facts.session.speed_index, u8(3))
	testing.expect(t, effects.execute({kind = .Cycle_Speed}))
	testing.expect_value(t, engine.begin().data.facts.session.speed_index, u8(0))
	testing.expect(t, !effects.execute({kind = .Select, combatant = 2}))
	testing.expect_value(t, engine.begin().data.ui.selected, i32(1))
	battle := engine.begin()
	battle.data = {facts = training_battle()}
	testing.expect(t, engine.commit(&battle))
	original := battle.data
	battle.data.facts.items[1][0] = .Fireball
	testing.expect(t, !engine.commit(&battle), "Items cannot belong to both players")
	testing.expect_value(t, engine.begin().data, original)
	battle = engine.begin()
	battle.data.facts.cooldowns[0][15] = 1
	testing.expect(t, !engine.commit(&battle), "Empty slots cannot have cooldowns")
	battle = engine.begin()
	battle.data.facts.battle.ticks = 2
	battle.data.facts.bodies[0].lava_ticks = 2
	testing.expect(t, engine.commit(&battle))
	battle.data.facts.battle.ticks = 1
	testing.expect(t, !engine.commit(&battle), "Lava exposure cannot exceed elapsed Battle Ticks, even when only the clock changes")
	testing.expect(t, effects.execute({kind = .Pick_Items}), "Returning to the picker clears Battle exposure")
}

// ---------------- File ----------------

@(private = "file")
training_battle :: proc() -> state.Facts {
	facts: state.Facts
	for spell in catalog.Spell.Fireball..=catalog.Spell.Swap {facts.items[0][int(spell) - 1] = spell}
	procedures.start_battle(&facts)
	facts.cooldowns = {}
	for &c in facts.combatants {c.armor = 0; c.reflex = 0}
	return facts
}
