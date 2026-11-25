package schema

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:fmt"
import "core:os"

// ---------------- Project ----------------

import "../../src/state"

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("Usage: schema runtime|persistence")
		os.exit(1)
	}
	output: string
	switch os.args[1] {
	case "runtime":
		output = generate({state.Store},
			"Authoritative state: Facts survives player saves; UI and Notice survive development reloads only.\n" +
			"Combatant and Activity arrays share combatant-position keys. UI.selected is a combatant index.\n" +
			"Session.speed_index selects catalog.SIMULATION_SPEEDS. Immutable catalog values and derived/runtime resources are outside Store.")
	case "persistence":
		output = generate({state.Save_File, state.Reload_Snapshot}, fmt.tprintf(
			"Player save version %d contains Facts. Development reload version %d contains the entire Store.\n" +
			"JSON uses these field names and array order. Runtime resources and engine bookkeeping are reconstructed.",
			state.SAVE_VERSION, state.RELOAD_VERSION))
	case:
		fmt.eprintln("Usage: schema runtime|persistence")
		os.exit(1)
	}
	defer delete(output)
	fmt.print(output)
}
