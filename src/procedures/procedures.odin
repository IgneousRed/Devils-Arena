package procedures

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:math"
import "core:math/rand"

// ---------------- Project ----------------

import "../catalog"
import "../engine"
import "../functions"
import "../state"
import "../views"

// -------------------------------- Constants --------------------------------

// ---------------- Public ----------------

// Provisional lava tuning; starting HP supplies the common stat-scale reference.
LAVA_SCALE :: f64(1e-8)

// ---------------- File ----------------

@(private = "file")
SPAWN_OFFSET :: f64(170)

@(private = "file")
KNOCKBACK_DRAG :: f64(5)

// -------------------------------- Types --------------------------------

// ---------------- File ----------------

// Tick-local increments: no effect reads another effect's output.
@(private = "file")
Battle_Change :: struct {health, armor, x, y, vx, vy: f64}

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

reduce :: proc(tx: ^engine.Transaction, command: state.Command) {
	switch command.kind {
	case .Select:
		tx.data.ui.selected = command.combatant
	case .Cycle_Speed:
		tx.data.facts.session.speed_index = (tx.data.facts.session.speed_index + 1) % u8(len(catalog.SIMULATION_SPEEDS))
	case .Scroll:
		tx.data.ui.scroll = command.scroll
	case .Reset:
		tx.data = {notice = .Reset}
	case .Pick:
		if tx.data.facts.battle.phase != .Picking || command.spell <= .None || command.spell > .Swap {return}
		for items in tx.data.facts.items {if functions.item_slot(items, command.spell) >= 0 {return}}
		for &spell in tx.data.facts.items[0] {if spell == .None {spell = command.spell; break}}
	case .Start_Battle:
		if tx.data.facts.battle.phase != .Picking || !functions.has_items(tx.data.facts.items[0]) {return}
		start_battle(&tx.data.facts)
		tx.data.ui.scroll = 0
		tx.data.notice = .None
	case .Restart_Battle:
		if tx.data.facts.battle.phase != .Picking {start_battle(&tx.data.facts); tx.data.ui.scroll = 0; tx.data.notice = .None}
	case .Pick_Items:
		tx.data.facts.battle = {seed = tx.data.facts.battle.seed}
		tx.data.facts.spells = {}
		tx.data.facts.cooldowns = {}
		for &body in tx.data.facts.bodies {body.lava_ticks = 0}
		tx.data.ui.scroll = 0
		tx.data.notice = .None
	case .None, .Save, .Load:
	}
}

stage_load :: proc(tx: ^engine.Transaction, facts: state.Facts) {
	tx.data = {facts = facts, notice = .Loaded}
}

start_battle :: proc(facts: ^state.Facts) {
	seed := facts.battle.seed + 1
	for &body, id in facts.bodies {
		base := catalog.STARTING_STAT
		body = {x = -SPAWN_OFFSET if id == 0 else SPAWN_OFFSET, starting_health = base}
		facts.combatants[id] = {base, base, base, base, base, base}
	}
	for items, id in facts.items {
		for spell, slot in items {facts.cooldowns[id][slot] = catalog.SPELLS[spell].cooldown}
	}
	facts.spells = {}
	facts.battle = {phase = .Active, seed = seed}
}

battle_tick :: proc(facts: ^state.Facts, inputs: [catalog.COMBATANT_COUNT]state.Battle_Input) -> bool {
	if facts.battle.phase != .Active {return true}
	before := facts^
	outcomes, defined := battle_outcomes(&before)
	if !defined {return false}
	changes: [catalog.COMBATANT_COUNT]Battle_Change
	dt := catalog.TICK_SECONDS
	radius := functions.arena_radius(before.battle.ticks)
	for body, id in before.bodies {
		input := inputs[id]
		mx, my := clamp(input.move_x, -1, 1), clamp(input.move_y, -1, 1)
		length := math.sqrt(mx * mx + my * my)
		if length > 1 {mx /= length; my /= length}
		changes[id] = {
			x = (mx * catalog.MOVE_SPEED + body.vx) * dt,
			y = (my * catalog.MOVE_SPEED + body.vy) * dt,
			vx = -body.vx * (KNOCKBACK_DRAG * dt),
			vy = -body.vy * (KNOCKBACK_DRAG * dt),
		}
		if body.x * body.x + body.y * body.y > radius * radius {
			facts.bodies[id].lava_ticks += 1
			exposure := f64(facts.bodies[id].lava_ticks)
			damage := body.starting_health * (LAVA_SCALE * exposure * exposure)
			health, armor := functions.armor_damage(before.combatants[id], damage)
			changes[id].health -= health
			changes[id].armor -= armor
		}
	}
	for &spell in facts.spells {
		if spell.spell == .None {continue}
		if spell.remaining <= 0 {spell = {}; continue}
		previous := spell.remaining
		spell.remaining = max(0, previous - dt)
		target := 1 - int(spell.owner)
		body := before.bodies[target]
		definition := catalog.SPELLS[spell.spell]
		multiplier := functions.spell_multiplier(outcomes, int(spell.owner))
		switch spell.spell {
		case .Fireball, .Swap:
			nx, ny := spell.x + spell.vx * dt, spell.y + spell.vy * dt
			if functions.segment_hits(spell.x, spell.y, nx, ny, body.x, body.y, catalog.BODY_RADIUS + definition.radius) {
				if multiplier != 0 {
					if spell.spell == .Swap {
						caster := before.bodies[spell.owner]
						changes[spell.owner].x += body.x - caster.x
						changes[spell.owner].y += body.y - caster.y
						changes[target].x += caster.x - body.x
						changes[target].y += caster.y - body.y
					} else {hit(&before, &changes[target], target, definition, multiplier, spell.vx, spell.vy)}
				}
				spell = {}
				continue
			}
			spell.x, spell.y = nx, ny
		case .Meteor:
			if previous > catalog.METEOR_FLASH_SECONDS && spell.remaining <= catalog.METEOR_FLASH_SECONDS && multiplier != 0 {
				dx, dy := body.x - spell.x, body.y - spell.y
				if dx * dx + dy * dy <= (definition.radius + catalog.BODY_RADIUS) * (definition.radius + catalog.BODY_RADIUS) {
					hit(&before, &changes[target], target, definition, multiplier, dx, dy)
				}
			}
		case .None, .Lightning, .Teleport:
		}
		if spell.remaining == 0 {spell = {}}
	}
	// New persistent spells begin advancing next Tick, from the starting snapshot's origin.
	for input, id in inputs {
		progress := dt * functions.cooldown_rate(before.combatants[id].speed, before.combatants[1 - id].speed)
		// Inventory order is presentation data. Resolve saturated pools in stable
		// player/spell order, using only the starting inventory and cooldowns.
		for spell in catalog.Spell.Fireball..=catalog.Spell.Swap {
			slot := functions.item_slot(before.items[id], spell)
			if slot < 0 {continue}
			remaining := before.cooldowns[id][slot] - progress
			if spell in input.casts && remaining <= 0 {
				effect_slot := -1
				cosmetic_slot := -1
				for existing, candidate in facts.spells {
					if existing.spell == .None {effect_slot = candidate; break}
					if existing.spell == .Lightning || existing.spell == .Teleport {
						if cosmetic_slot < 0 || existing.remaining < facts.spells[cosmetic_slot].remaining {cosmetic_slot = candidate}
					}
				}
				// Persistent effects need a free or reclaimable cosmetic slot;
				// instant effects still execute when their flash cannot be stored.
				persistent := spell == .Fireball || spell == .Swap || spell == .Meteor
				if effect_slot < 0 && persistent {effect_slot = cosmetic_slot}
				if effect_slot >= 0 || !persistent {
					definition := catalog.SPELLS[spell]
					caster := before.bodies[id]
					target_id := 1 - id
					target := before.bodies[target_id]
					// Keep cursor direction independent of world-bounded destinations.
					ax, ay := input.aim_x, input.aim_y
					if ax == caster.x && ay == caster.y {ax, ay = target.x, target.y}
					dx, dy := functions.direction(ax - caster.x, ay - caster.y)
					effect := state.Spell_Effect{spell = spell, owner = u8(id), x = caster.x, y = caster.y, remaining = definition.lifetime}
					switch spell {
					case .Fireball, .Swap:
						effect.vx, effect.vy = dx * definition.projectile_speed, dy * definition.projectile_speed
						effect.x += dx * (catalog.BODY_RADIUS + definition.radius)
						effect.y += dy * (catalog.BODY_RADIUS + definition.radius)
					case .Lightning:
						effect.vx, effect.vy = dx * (catalog.WORLD_LIMIT * 2 * math.SQRT_TWO), dy * (catalog.WORLD_LIMIT * 2 * math.SQRT_TWO)
						multiplier := functions.spell_multiplier(outcomes, id)
						if multiplier != 0 && functions.segment_hits(caster.x, caster.y, caster.x + effect.vx, caster.y + effect.vy,
							target.x, target.y, catalog.BODY_RADIUS + definition.radius) {
							hit(&before, &changes[target_id], target_id, definition, multiplier, dx, dy)
						}
					case .Meteor:
						effect.x, effect.y = functions.clamp_target(ax, ay)
					case .Teleport:
						distance := min(definition.range, math.hypot(ax - caster.x, ay - caster.y))
						changes[id].x += dx * distance
						changes[id].y += dy * distance
					case .None:
					}
					if effect_slot >= 0 {facts.spells[effect_slot] = effect}
					remaining += definition.cooldown
				}
			}
			facts.cooldowns[id][slot] = max(0, remaining)
		}
	}
	for change, id in changes {
		body := before.bodies[id]
		facts.bodies[id].x, facts.bodies[id].y = functions.clamp_target(body.x + change.x, body.y + change.y)
		facts.bodies[id].vx, facts.bodies[id].vy = body.vx + change.vx, body.vy + change.vy
		stats := before.combatants[id]
		facts.combatants[id].health = max(0, stats.health + change.health)
		facts.combatants[id].armor = max(0, stats.armor + change.armor)
	}
	facts.battle.ticks += 1
	player, dummy := facts.combatants[0].health, facts.combatants[1].health
	if player == 0 || dummy == 0 || facts.battle.ticks == catalog.BATTLE_TICKS {
		facts.battle.phase = .Player_Won if player > dummy else .Dummy_Won if dummy > player else .Draw
		if dummy == 0 && player > 0 && facts.session.kills < max(u32) {facts.session.kills += 1}
	}
	return true
}

// RNG advancement stays in procedures, using only this Tick's private generator.
battle_outcomes :: proc(facts: ^state.Facts) -> (outcomes: views.Battle_Outcomes, ok: bool) {
	// Do not invent the deliberately deferred 0/0 rules. Callers leave this Tick unpublished.
	for c, id in facts.combatants {
		opponent := facts.combatants[1 - id]
		// Visiting both players also checks the reversed Reflex/Mastery pairing.
		if max(c.health, c.armor) == 0 || max(c.speed, opponent.speed) == 0 ||
		   max(c.mastery, opponent.reflex) == 0 {return}
	}
	// Randomness is reconstructible from seed and Tick; no RNG cache needs saving.
	random := rand.create(u64(facts.battle.seed) << 32 | u64(facts.battle.ticks))
	generator := rand.default_random_generator(&random)
	for c, id in facts.combatants {
		opponent := facts.combatants[1 - id]
		outcomes.critical[id] = rand.float64(generator) < functions.stat_share(c.mastery, opponent.reflex)
		outcomes.dodge[id] = rand.float64(generator) < functions.stat_share(c.reflex, opponent.mastery)
	}
	return outcomes, true
}

// ---------------- File ----------------

@(private = "file")
hit :: proc(before: ^state.Facts, change: ^Battle_Change, target: int, definition: catalog.Spell_Definition, multiplier, x, y: f64) {
	dx, dy := functions.direction(x, y)
	damage := definition.damage * before.bodies[target].starting_health * multiplier
	health, armor := functions.armor_damage(before.combatants[target], damage)
	change.health -= health
	change.armor -= armor
	change.vx += dx * definition.knockback
	change.vy += dy * definition.knockback
}
