package views

// -------------------------------- Imports --------------------------------

// ---------------- Project ----------------

import "../state"

// -------------------------------- Types --------------------------------

// ---------------- Public ----------------

Overview :: struct {
	selected: i32,
	stats: [6]f64,
	activity: state.Activity,
	kills: u32,
	simulation_speed: u8,
	critical_chance, dodge_chance, cooldown_rate: f64,
	critical_defined, dodge_defined, cooldown_defined: bool,
}

Battle_Outcomes :: struct {critical, dodge: [2]bool}
