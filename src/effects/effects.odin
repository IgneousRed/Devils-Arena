package effects

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
import "core:encoding/json"

// ---------------- Project ----------------

import "../engine"
import "../functions"
import "../procedures"
import "../state"
when ODIN_OS == .JS {
	foreign import browser "env"
}

// -------------------------------- Constants --------------------------------

// ---------------- Public ----------------

when ODIN_OS != .JS {
	SAVE_PATH :: ".local/data/save.json"
}

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

record_start :: proc() {
	recording_begin()
	bytes, err := json.marshal(state.Recording_Header{format = 1, build = state.APPLICATION_VERSION,
		initial = {version = state.RELOAD_VERSION, data = engine.begin().data}}, allocator = context.temp_allocator)
	if err == nil {recording_emit(bytes)}
}

record_end :: proc() {
	defer recording_finish()
	bytes, err := json.marshal(state.Recording_End{final = {version = state.RELOAD_VERSION, data = engine.begin().data}}, allocator = context.temp_allocator)
	if err == nil {recording_emit(bytes)}
}

execute :: proc(command: state.Command, storage: ^state.Storage_Result = nil, replay := false) -> bool {
	if replay && storage == nil {return false}
	tx := engine.begin()
	switch command.kind {
	case .None:
		return true
	case .Save:
		bytes, encoded := functions.encode_save(tx.data.facts)
		stored := false
		if encoded {
			stored = storage.write_ok if replay else write_save(bytes)
			if storage != nil {
				storage.write_ok = stored
				if !replay {record_event({kind = .Storage, storage = storage^})}
			}
		}
		if !encoded || !stored {notify(.Storage_Error); return false}
		tx.data.notice = .Saved
	case .Load:
		bytes: []u8
		loaded := false
		if replay {bytes, loaded = storage.bytes, storage.read_ok}
		else {bytes, loaded = read_save()}
		if storage != nil {
			storage.bytes, storage.read_ok = bytes, loaded
			if !replay {record_event({kind = .Storage, storage = storage^})}
		}
		file, decoded := functions.decode_save(bytes)
		if !loaded || !decoded {notify(.Invalid_Data); return false}
		procedures.stage_load(&tx, file.facts)
	case .Select, .Cycle_Speed, .Scroll, .Reset, .Pick, .Start_Battle, .Restart_Battle, .Pick_Items:
		procedures.reduce(&tx, command)
	}
	if commit(&tx) {return true}
	notify(.Invalid_Data)
	return false
}

restore :: proc(bytes: []u8, replay := false) -> bool {
	if !replay {record_event({kind = .Restore, data = bytes})}
	snapshot, decoded := functions.decode_reload(bytes)
	if !decoded {return false}
	tx := engine.begin()
	tx.data = snapshot.data
	return commit(&tx)
}

// The application chooses tick scheduling; procedures alone change combat facts.
tick :: proc(input: state.Battle_Input) -> bool {
	tx := engine.begin()
	if !procedures.battle_tick(&tx.data.facts, {input, {}}) {notify(.Rules_Undefined); return false}
	if commit(&tx) {return true}
	notify(.Invalid_Data)
	return false
}

when ODIN_OS == .JS {
	foreign browser {
		devil_record :: proc "c" (data: [^]u8, size: i32) ---
		devil_save :: proc "c" (data: [^]u8, size: i32) -> i32 ---
		devil_load :: proc "c" (data: [^]u8, capacity: i32) -> i32 ---
	}
}

record_event :: proc(event: state.Recording_Event) {
	bytes, err := json.marshal(event, allocator = context.temp_allocator)
	if err == nil {recording_emit(bytes)}
}

// ---------------- File ----------------

@(private = "file")
notify :: proc(notice: state.Notice) -> bool {
	tx := engine.begin()
	tx.data.notice = notice
	return commit(&tx)
}

@(private = "file")
commit :: proc(tx: ^engine.Transaction) -> bool {
	if engine.commit(tx) {return true}
	if ODIN_DEBUG {
		fmt.eprintf("Transaction rejected: %v, constraint %d, revision %d\n", tx.error, tx.constraint, tx.revision)
	}
	return false
}
