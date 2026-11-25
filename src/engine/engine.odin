package engine

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:math"

// ---------------- Project ----------------

import "../catalog"
import "../state"

// -------------------------------- Constants --------------------------------

// ---------------- Package ----------------

@(private = "package")
CONSTRAINT_COUNT :: ITEM_OWNERSHIP + 1

@(private = "package")
SPELLS :: BATTLE + 1

@(private = "package")
BATTLE :: BODIES + catalog.COMBATANT_COUNT

@(private = "package")
BODIES :: COOLDOWNS + catalog.COMBATANT_COUNT

@(private = "package")
COMBATANT :: 0

// ---------------- File ----------------

@(private = "file")
MAX_SPATIAL_VALUE :: f64(10000)

@(private = "file")
MAX_TIMER_SECONDS :: f64(60)

@(private = "file")
ITEM_OWNERSHIP :: ROW_COUNT

@(private = "file")
ROW_COUNT :: SPELLS + catalog.EFFECT_LIMIT

@(private = "file")
COOLDOWNS :: ITEMS + catalog.COMBATANT_COUNT

@(private = "file")
ITEMS :: NOTICE + 1

@(private = "file")
NOTICE :: UI_ROW + 1

@(private = "file")
UI_ROW :: SESSION + 1

@(private = "file")
SESSION :: ACTIVITY + catalog.COMBATANT_COUNT

@(private = "file")
ACTIVITY :: COMBATANT + catalog.COMBATANT_COUNT

// -------------------------------- Globals --------------------------------

// ---------------- Package ----------------

@(private = "package")
live: Live

// -------------------------------- Types --------------------------------

// ---------------- Public ----------------

Transaction :: struct {
	data: state.Store,
	revision: u64,
	checks: int,
	error: Commit_Error,
	constraint: int,
}

// ---------------- Package ----------------

@(private = "package")
Commit_Error :: enum {None, Stale, Invalid}

// ---------------- File ----------------

@(private = "file")
Live :: struct {
	data: state.Store,
	revision: u64,
	dependencies: [CONSTRAINT_COUNT]Dependencies,
	initialized: bool,
}

@(private = "file")
Query :: struct {
	data: ^state.Store,
	reads: Dependencies,
}

@(private = "file")
Dependencies :: bit_set[0..<ROW_COUNT; u64]

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

// Callers own the returned copy; no pointer into the live store escapes this package.
begin :: proc() -> Transaction {
	return {data = live.data, revision = live.revision}
}

// New dependencies publish with the facts, so rejection preserves both atomically.
commit :: proc(tx: ^Transaction) -> bool {
	tx.checks = 0
	tx.error, tx.constraint = .None, -1
	if tx.revision != live.revision {tx.error = .Stale; return false}
	changed: Dependencies
	for id in 0..<catalog.COMBATANT_COUNT {
		if tx.data.facts.combatants[id] != live.data.facts.combatants[id] {changed += {COMBATANT + id}}
		if tx.data.facts.activity[id] != live.data.facts.activity[id] {changed += {ACTIVITY + id}}
		if tx.data.facts.items[id] != live.data.facts.items[id] {changed += {ITEMS + id}}
		if tx.data.facts.cooldowns[id] != live.data.facts.cooldowns[id] {changed += {COOLDOWNS + id}}
		if tx.data.facts.bodies[id] != live.data.facts.bodies[id] {changed += {BODIES + id}}
	}
	if tx.data.facts.session != live.data.facts.session {changed += {SESSION}}
	if tx.data.ui != live.data.ui {changed += {UI_ROW}}
	if tx.data.notice != live.data.notice {changed += {NOTICE}}
	if tx.data.facts.battle != live.data.facts.battle {changed += {BATTLE}}
	for row, id in tx.data.facts.spells {if row != live.data.facts.spells[id] {changed += {SPELLS + id}}}
	if live.initialized && changed == {} {return true}
	pending := live.dependencies
	for key in 0..<CONSTRAINT_COUNT {
		if live.initialized && live.dependencies[key] & changed == {} {continue}
		query := Query{data = &tx.data}
		tx.checks += 1
		if key < ROW_COUNT {query.reads += {key}}
		valid := false
		switch {
		case key < ACTIVITY:
			row := query.data.facts.combatants[key - COMBATANT]
			valid = true
			for value in ([6]f64{row.health, row.armor, row.power, row.speed, row.reflex, row.mastery}) {
				if !finite(value) || value < 0 {valid = false; break}
			}
		case key < SESSION:
			row := query.data.facts.activity[key - ACTIVITY]
			valid = finite(row.move_progress) && row.move_progress >= 0
		case key == SESSION:
			valid = int(query.data.facts.session.speed_index) < len(catalog.SIMULATION_SPEEDS)
		case key == UI_ROW:
			row := query.data.ui
			valid = row.selected >= 0 && row.selected < catalog.COMBATANT_COUNT && finite(f64(row.scroll)) && row.scroll >= 0
		case key == NOTICE:
			valid = query.data.notice <= .Rules_Undefined
		case key < COOLDOWNS:
			valid = true
			for spell in query.data.facts.items[key - ITEMS] {if spell > .Swap {valid = false; break}}
		case key < BODIES:
			id := key - COOLDOWNS
			items := read_items(&query, id)
			valid = true
			for value, slot in query.data.facts.cooldowns[id] {
				if !finite(value) || value < 0 || value > MAX_TIMER_SECONDS || (items[slot] == .None && value != 0) {valid = false; break}
			}
		case key < BATTLE:
			row := query.data.facts.bodies[key - BODIES]
			valid = true
			for value in ([2]f64{row.x, row.y}) {
				if !finite(value) || abs(value) > MAX_SPATIAL_VALUE {valid = false; break}
			}
			// Subscribe to Battle only after all local body checks succeed.
			if valid {
				valid = finite(row.vx) && finite(row.vy) && finite(row.starting_health) && row.starting_health >= 0
				if valid {
					query.reads += {BATTLE}
					valid = row.lava_ticks <= query.data.facts.battle.ticks
				}
			}
		case key == BATTLE:
			row := query.data.facts.battle
			valid = row.phase <= .Draw && row.ticks <= catalog.BATTLE_TICKS
			if valid && row.phase != .Picking {
				for id in 0..<catalog.COMBATANT_COUNT {
					query.reads += {BODIES + id}
					if query.data.facts.bodies[id].starting_health <= 0 {valid = false; break}
				}
				if valid {
					player, dummy := read_combatant(&query, 0).health, read_combatant(&query, 1).health
					ended := player == 0 || dummy == 0 || row.ticks == catalog.BATTLE_TICKS
					if row.phase == .Active {valid = !ended}
					else {
						winner: state.Battle_Phase = .Player_Won if player > dummy else .Dummy_Won if dummy > player else .Draw
						valid = ended && row.phase == winner
					}
				}
			}
		case key < ROW_COUNT:
			row := query.data.facts.spells[key - SPELLS]
			if row.spell == .None {valid = row == state.Spell_Effect{}}
			else if row.spell <= .Swap && row.owner < catalog.COMBATANT_COUNT {
				valid = true
				for value in ([4]f64{row.x, row.y, row.vx, row.vy}) {
					if !finite(value) || abs(value) > MAX_SPATIAL_VALUE {valid = false; break}
				}
				if valid {valid = finite(row.remaining) && row.remaining > 0 && row.remaining <= MAX_TIMER_SECONDS}
			}
		case key == ITEM_OWNERSHIP:
			seen: bit_set[catalog.Spell; u8]
			valid = true
			for id in 0..<catalog.COMBATANT_COUNT {
				for spell in read_items(&query, id) {
					if spell > .Swap {valid = false; break}
					if spell == .None {continue}
					if spell in seen {valid = false; break}
					seen += {spell}
				}
				if !valid {break}
			}
		}
		if !valid {tx.error, tx.constraint = .Invalid, key; return false}
		pending[key] = query.reads
	}
	live = {data = tx.data, revision = live.revision + 1, dependencies = pending, initialized = true}
	tx.revision = live.revision
	return true
}

// ---------------- File ----------------

@(private = "file")
read_items :: proc(q: ^Query, id: int) -> [catalog.ITEM_LIMIT]catalog.Spell {
	q.reads += {ITEMS + id}
	return q.data.facts.items[id]
}

@(private = "file")
read_combatant :: proc(q: ^Query, id: int) -> state.Combatant {
	q.reads += {COMBATANT + id}
	return q.data.facts.combatants[id]
}

@(private = "file")
finite :: proc(value: f64) -> bool {return !math.is_nan(value) && !math.is_inf(value)}
