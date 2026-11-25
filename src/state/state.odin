package state

// -------------------------------- Imports --------------------------------

// ---------------- Project ----------------

import "../catalog"

// -------------------------------- Constants --------------------------------

// ---------------- Public ----------------

APPLICATION_VERSION :: #config(APPLICATION_VERSION, "unversioned")

SAVE_VERSION :: u32(3)

RELOAD_VERSION :: u32(3)

MAX_SAVE_BYTES :: 16 * 1024

MAX_RECORDING_BYTES :: 64 * 1024 * 1024

// -------------------------------- Types --------------------------------

// ---------------- Public ----------------

Recording_Header :: struct {format: u32, build: string, initial: Reload_Snapshot}

Recording_Event :: struct {kind: Recording_Kind, frame: Frame_Input, storage: Storage_Result, data: []u8}

Recording_Kind :: enum {Frame, Restore, Storage}

Recording_End :: struct {final: Reload_Snapshot}

// Samples at the application boundary, before layout/input interpretation.
Frame_Input :: struct {
	width, height: i32,
	pixel_ratio, scroll, mouse_x, mouse_y: f32,
	seconds: f64,
	focused, left_pressed, save_pressed, load_pressed, close: bool,
	keys: bit_set[Input_Key; u32],
}

Input_Key :: enum {W, A, S, D, Q, E, R, F, Space, Left_Control, Right_Control, Left_Super, Right_Super, Left_Alt, Right_Alt}

// Results consumed by Save/Load. Replay supplies these without accessing storage.
Storage_Result :: struct {bytes: []u8, read_ok, write_ok: bool}

Battle_Input :: struct {
	move_x, move_y, aim_x, aim_y: f64,
	casts: bit_set[catalog.Spell; u8],
}

Save_File :: struct {
	version: u32,
	facts: Facts,
}

Reload_Snapshot :: struct {
	version: u32,
	data: Store,
}

Store :: struct {
	facts: Facts,
	ui: UI,
	notice: Notice,
}

Facts :: struct {
	combatants: [catalog.COMBATANT_COUNT]Combatant,
	activity: [catalog.COMBATANT_COUNT]Activity,
	session: Session,
	items: [catalog.COMBATANT_COUNT][catalog.ITEM_LIMIT]catalog.Spell,
	cooldowns: [catalog.COMBATANT_COUNT][catalog.ITEM_LIMIT]f64,
	bodies: [catalog.COMBATANT_COUNT]Body,
	battle: Battle,
	spells: [catalog.EFFECT_LIMIT]Spell_Effect,
}

// Array positions are primary keys. No second copy of these facts is stored in a view.
Combatant :: struct {
	health, armor, power, speed, reflex, mastery: f64,
}

Activity :: struct {
	dodges, misses: u32,
	move_progress: f64,
}

Session :: struct {
	kills: u32,
	speed_index: u8,
}

// A zero battle is an empty pick phase. All live combat data crosses the same commit boundary.
Battle_Phase :: enum u8 {Picking = 0, Active = 1, Player_Won = 2, Dummy_Won = 3, Draw = 4}

Body :: struct {x, y, vx, vy, starting_health: f64, lava_ticks: u32}

Spell_Effect :: struct {
	spell: catalog.Spell,
	owner: u8,
	// vx/vy are projectile velocity, or Lightning's fixed beam displacement.
	x, y, vx, vy, remaining: f64,
}

UI :: struct {
	selected: i32,
	scroll: f32,
}

Notice :: enum u8 {
	None = 0,
	Saved = 1,
	Loaded = 2,
	Reset = 3,
	Invalid_Data = 4,
	Storage_Error = 5,
	Rules_Undefined = 6,
}

Command :: struct {
	kind: Command_Kind,
	combatant: i32,
	scroll: f32,
	spell: catalog.Spell,
}

// ---------------- File ----------------

@(private = "file")
Battle :: struct {phase: Battle_Phase, ticks, seed: u32}

@(private = "file")
Command_Kind :: enum {
	None,
	Select,
	Cycle_Speed,
	Scroll,
	Reset,
	Save,
	Load,
	Pick,
	Start_Battle,
	Restart_Battle,
	Pick_Items,
}
