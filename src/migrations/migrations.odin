package migrations

// -------------------------------- Imports --------------------------------

// ---------------- Project ----------------

import "../catalog"
import "../state"

// -------------------------------- Constants --------------------------------

// ---------------- Public ----------------

V1_VERSION :: u32(1)

V2_VERSION :: u32(2)

V3_VERSION :: u32(3)

// ---------------- File ----------------

@(private = "file")
V3_NEW_STAT :: f64(100) // Historical migration default, independent of new-game tuning.

// -------------------------------- Types --------------------------------

// ---------------- Public ----------------

Save_V1 :: struct {version: u32, facts: Facts_V1}

Reload_V1 :: struct {version: u32, data: Store_V1}

Save_V2 :: struct {version: u32, facts: Facts_V2}

Reload_V2 :: struct {version: u32, data: Store_V2}

Spell_V2 :: enum u8 {None = 0, Fireball = 1, Lightning = 2, Meteor = 3, Teleport = 4, Swap = 5}

// ---------------- File ----------------

@(private = "file")
Store_V1 :: struct {facts: Facts_V1, ui: UI_V1, notice: Notice_V1}

@(private = "file")
Facts_V1 :: struct {
	combatants: [2]Combatant_V1,
	activity: [2]Activity_V1,
	session: Session_V1,
}

@(private = "file")
Store_V2 :: struct {facts: Facts_V2, ui: UI_V1, notice: Notice_V1}

@(private = "file")
UI_V1 :: struct {selected: i32, scroll: f32}

@(private = "file")
Notice_V1 :: enum u8 {None, Saved, Loaded, Reset, Invalid_Data, Storage_Error}

@(private = "file")
Facts_V2 :: struct {
	combatants: [2]Combatant_V1,
	activity: [2]Activity_V1,
	session: Session_V1,
	items: [2][16]Spell_V2,
	cooldowns: [2][16]f64,
	bodies: [2]Body_V2,
	battle: Battle_V2,
	spells: [32]Spell_Effect_V2,
}

// Retain the exact v1 shapes so older saves and per-tab recovery snapshots remain readable.
@(private = "file")
Combatant_V1 :: struct {health, armor, agility, speed, power: f64}

@(private = "file")
Activity_V1 :: struct {dodges, misses: u32, move_progress: f64}

@(private = "file")
Session_V1 :: struct {kills: u32, speed_index: u8}

@(private = "file")
Battle_V2 :: struct {phase: Battle_Phase_V2, ticks: u32}

// Exact v2 persistence shapes. Retain these alongside v1 for older tabs and saves.
@(private = "file")
Battle_Phase_V2 :: enum u8 {Picking, Active, Player_Won, Dummy_Won, Draw}

@(private = "file")
Body_V2 :: struct {x, y, vx, vy, starting_health: f64}

@(private = "file")
Spell_Effect_V2 :: struct {spell: Spell_V2, owner: u8, x, y, vx, vy, remaining: f64}

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

store_v1_to_v2 :: proc(old: Store_V1) -> Store_V2 {
	return {facts = facts_v1_to_v2(old.facts), ui = old.ui, notice = old.notice}
}

facts_v1_to_v2 :: proc(old: Facts_V1) -> Facts_V2 {
	return {combatants = old.combatants, activity = old.activity, session = old.session}
}

store_v2_to_v3 :: proc(old: Store_V2) -> state.Store {
	return {facts = facts_v2_to_v3(old.facts), ui = {old.ui.selected, old.ui.scroll}, notice = state.Notice(old.notice)}
}

facts_v2_to_v3 :: proc(old: Facts_V2) -> state.Facts {
	result: state.Facts
	for c, id in old.combatants {
		// Agility never affected practice combat; it is removed, not reinterpreted as Reflex.
		result.combatants[id] = {
			health = max(0, c.health), armor = max(0, c.armor), power = max(0, c.power), speed = max(0, c.speed),
			reflex = V3_NEW_STAT, mastery = V3_NEW_STAT,
		}
	}
	for a, id in old.activity {result.activity[id] = {a.dodges, a.misses, a.move_progress}}
	result.session = {old.session.kills, old.session.speed_index}
	for items, id in old.items {for spell, slot in items {result.items[id][slot] = spell_v2_to_v3(spell)}}
	result.cooldowns = old.cooldowns
	for b, id in old.bodies {result.bodies[id] = {b.x, b.y, b.vx, b.vy, b.starting_health, 0}}
	result.battle = {phase = state.Battle_Phase(old.battle.phase), ticks = old.battle.ticks}
	for s, id in old.spells {result.spells[id] = {spell_v2_to_v3(s.spell), s.owner, s.x, s.y, s.vx, s.vy, s.remaining}}
	// Legacy combat had neither a random stream nor cumulative lava exposure to reconstruct.
	return result
}

// ---------------- File ----------------

@(private = "file")
spell_v2_to_v3 :: proc(old: Spell_V2) -> catalog.Spell {
	switch old {
	case .None: return .None
	case .Fireball: return .Fireball
	case .Lightning: return .Lightning
	case .Meteor: return .Meteor
	case .Teleport: return .Teleport
	case .Swap: return .Swap
	}
	unreachable()
}
