#+test
#+private file
package schema

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:strings"
import "core:testing"

// ---------------- Project ----------------

import "../../src/state"

// -------------------------------- Types --------------------------------

// ---------------- File ----------------

Fixture_Root :: struct {rows: [3]Fixture_Row, selected: Fixture_Row}

Fixture_Row :: struct {left, right: f32, mode: Fixture_Mode}

// A separate schema proves generation follows types beyond the current game rows.
Fixture_Mode :: enum u8 {Idle = 0, Moving = 7}

// -------------------------------- Procedures --------------------------------

// ---------------- File ----------------

@(test)
nested_types_and_shared_rows :: proc(t: ^testing.T) {
	output := generate({Fixture_Root}, "Fixture")
	defer delete(output)
	for expected in ([]string{
		"Project devils_arena {",
		"Table Fixture_Root {",
		"rows \"[3]Fixture_Row\" [not null]",
		"left \"f32\" [not null]",
		"right \"f32\" [not null]",
		"Ref: Fixture_Root.rows < Fixture_Row.__diagram_id",
		"Ref: Fixture_Root.selected - Fixture_Row.__diagram_id",
		"Enum Fixture_Mode {",
		"Moving [note: 'Odin value 7']",
	}) {testing.expect(t, strings.contains(output, expected), expected)}
	testing.expect_value(t, strings.count(output, "Table Fixture_Row {"), 1)
	testing.expect(t, !strings.contains(output, "%!"), "Formatting must produce literal DBML braces")
}

@(test)
storage_roots_share_facts_and_exclude_commands :: proc(t: ^testing.T) {
	output := generate({state.Save_File, state.Reload_Snapshot}, "Persistence")
	defer delete(output)
	for expected in ([]string{
		"Ref: Save_File.facts - Facts.__diagram_id",
		"Ref: Reload_Snapshot.data - Store.__diagram_id",
		"Ref: Store.ui - UI.__diagram_id",
		"Enum Notice {",
	}) {testing.expect(t, strings.contains(output, expected), expected)}
	testing.expect_value(t, strings.count(output, "Table Facts {"), 1)
	testing.expect(t, !strings.contains(output, "Table Command"))
}
