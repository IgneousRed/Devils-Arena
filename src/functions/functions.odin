package functions

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:encoding/json"
import "core:math"
import "core:reflect"
import "core:strings"

// ---------------- Project ----------------

import "../catalog"
import "../migrations"
import "../state"
import "../views"

// -------------------------------- Constants --------------------------------

// ---------------- File ----------------

@(private = "file")
MAX_JSON_DEPTH :: 16

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

// Returned lines belong to context.allocator and reference data. Drop a torn tail
// and conservatively withhold an incomplete trace's final Frame: its Storage
// response may have been lost. Newline-terminated malformed records remain errors.
recording_lines :: proc(data: []u8) -> []string {
	text := string(data)
	last_newline := strings.last_index(text, "\n")
	if last_newline >= 0 {
		event: state.Recording_Event
		end: state.Recording_End
		last := transmute([]u8)strings.trim_space(text[last_newline + 1:])
		if len(last) > 0 && !decode_json(last, &event, len(data)) && !decode_json(last, &end, len(data)) {
			text = text[:last_newline]
		}
	}
	text = strings.trim_space(text)
	last_newline = strings.last_index(text, "\n")
	if last_newline >= 0 {
		event: state.Recording_Event
		if decode_json(transmute([]u8)text[last_newline + 1:], &event, len(data)) && event.kind == .Frame {
			text = text[:last_newline]
		}
	}
	return strings.split(text, "\n", context.allocator)
}

valid_frame_input :: proc(input: state.Frame_Input) -> bool {
	if input.width <= 0 || input.height <= 0 || input.pixel_ratio <= 0 || input.seconds < 0 ||
	   input.keys - {.W, .A, .S, .D, .Q, .E, .R, .F, .Space, .Left_Control, .Right_Control, .Left_Super, .Right_Super, .Left_Alt, .Right_Alt} != {} {return false}
	for value in ([6]f64{f64(input.pixel_ratio), f64(input.scroll), f64(input.mouse_x), f64(input.mouse_y), input.seconds, f64(input.width) / f64(input.pixel_ratio)}) {
		if math.is_nan(value) || math.is_inf(value) {return false}
	}
	return true
}

arena_radius :: proc(ticks: u32) -> f64 {
	return catalog.ARENA_RADIUS * max(0, 1 - f64(ticks) / f64(catalog.BATTLE_TICKS))
}

overview :: proc(facts: state.Facts, ui: state.UI) -> views.Overview {
	row := facts.combatants[ui.selected]
	opponent := facts.combatants[1 - ui.selected]
	view := views.Overview{
		selected = ui.selected,
		stats = {row.health, row.armor, row.power, row.speed, row.reflex, row.mastery},
		activity = facts.activity[ui.selected],
		kills = facts.session.kills,
		simulation_speed = catalog.SIMULATION_SPEEDS[facts.session.speed_index],
		critical_defined = max(row.mastery, opponent.reflex) > 0,
		dodge_defined = max(row.reflex, opponent.mastery) > 0,
		cooldown_defined = max(row.speed, opponent.speed) > 0,
	}
	if view.critical_defined {view.critical_chance = stat_share(row.mastery, opponent.reflex)}
	if view.dodge_defined {view.dodge_chance = stat_share(row.reflex, opponent.mastery)}
	if view.cooldown_defined {view.cooldown_rate = cooldown_rate(row.speed, opponent.speed)}
	return view
}

// Requires positive HP + Armor, checked before any Tick changes are applied.
armor_damage :: proc(stats: state.Combatant, damage: f64) -> (health, armor: f64) {
	// Compute both shares directly: subtracting a share near one erases small damage.
	reduced := stat_share(stats.health, stats.armor, amount = damage)
	return stat_share(stats.health, stats.armor, amount = reduced), stat_share(stats.armor, stats.health, amount = reduced)
}

// Normalize before summing; optionally weight an amount without losing tiny shares.
stat_share :: proc(a, b: f64, amount: f64 = 1) -> f64 {
	scale := max(a, b)
	relative_a, relative_b := a / scale, b / scale
	share := relative_a / (relative_a + relative_b)
	if share >= 0h0010000000000000 || a == 0 {return amount * share}
	// Below the smallest normal f64 (2^-1022), forming the share first can
	// lose a representable weighted result. Here a + b rounds to b; combine
	// binary exponents before rounding the final amount * a / b instead.
	a_mantissa, a_exponent := math.frexp(a)
	b_mantissa, b_exponent := math.frexp(b)
	amount_mantissa, amount_exponent := math.frexp(amount)
	return math.ldexp(amount_mantissa * a_mantissa / b_mantissa, amount_exponent + a_exponent - b_exponent)
}

// Requires positive combined Speed; the 0/0 rule remains deliberately undefined.
cooldown_rate :: proc(speed, opponent_speed: f64) -> f64 {
	return speed / opponent_speed if speed < opponent_speed else 1
}

spell_multiplier :: proc(outcomes: views.Battle_Outcomes, owner: int) -> f64 {
	critical, dodge := outcomes.critical[owner], outcomes.dodge[1 - owner]
	if dodge && !critical {return 0}
	return 2 if critical && !dodge else 1
}

has_items :: proc(items: [catalog.ITEM_LIMIT]catalog.Spell) -> bool {
	for spell in items {if spell != .None {return true}}
	return false
}

item_slot :: proc(items: [catalog.ITEM_LIMIT]catalog.Spell, spell: catalog.Spell) -> int {
	for item, slot in items {if item == spell {return slot}}
	return -1
}

// A segment query prevents fast spells tunnelling through the dummy between ticks.
segment_hits :: proc(ax, ay, bx, by, x, y, radius: f64) -> bool {
	dx, dy := bx - ax, by - ay
	length_squared := dx * dx + dy * dy
	fraction: f64
	if length_squared > 0 {fraction = clamp(((x - ax) * dx + (y - ay) * dy) / length_squared, 0, 1)}
	px, py := ax + fraction * dx - x, ay + fraction * dy - y
	return px * px + py * py <= radius * radius
}

direction :: proc(x, y: f64) -> (dx, dy: f64) {
	// Aim points can be any finite replay input. Scale before squaring so
	// neither enormous nor tiny nonzero vectors lose their direction.
	scale := max(abs(x), abs(y))
	if scale == 0 {return 0, 0}
	sx, sy := x / scale, y / scale
	length := math.sqrt(sx * sx + sy * sy)
	return sx / length, sy / length
}

clamp_target :: proc(x, y: f64) -> (f64, f64) {
	return clamp(x, -catalog.WORLD_LIMIT, catalog.WORLD_LIMIT), clamp(y, -catalog.WORLD_LIMIT, catalog.WORLD_LIMIT)
}

// Encoded bytes belong to context.temp_allocator until its next reset.
encode_save :: proc(facts: state.Facts) -> (data: []u8, ok: bool) {
	encoded, err := json.marshal(state.Save_File{state.SAVE_VERSION, facts}, allocator = context.temp_allocator)
	return encoded, err == nil && len(encoded) <= state.MAX_SAVE_BYTES
}

decode_save :: proc(data: []u8) -> (file: state.Save_File, ok: bool) {
	if decode_json(data, &file) && file.version == state.SAVE_VERSION {return file, true}
	previous: migrations.Save_V2
	if decode_json(data, &previous) && previous.version == migrations.V2_VERSION {
		return {version = migrations.V3_VERSION, facts = migrations.facts_v2_to_v3(previous.facts)}, true
	}
	old: migrations.Save_V1
	if decode_json(data, &old) && old.version == migrations.V1_VERSION {
		return {version = migrations.V3_VERSION, facts = migrations.facts_v2_to_v3(migrations.facts_v1_to_v2(old.facts))}, true
	}
	return {}, false
}

// Encoded bytes belong to context.temp_allocator until its next reset.
encode_reload :: proc(data: state.Store) -> (bytes: []u8, ok: bool) {
	encoded, err := json.marshal(state.Reload_Snapshot{state.RELOAD_VERSION, data}, allocator = context.temp_allocator)
	return encoded, err == nil && len(encoded) <= state.MAX_SAVE_BYTES
}

decode_reload :: proc(bytes: []u8) -> (snapshot: state.Reload_Snapshot, ok: bool) {
	if decode_json(bytes, &snapshot) && snapshot.version == state.RELOAD_VERSION {return snapshot, true}
	previous: migrations.Reload_V2
	if decode_json(bytes, &previous) && previous.version == migrations.V2_VERSION {
		return {version = migrations.V3_VERSION, data = migrations.store_v2_to_v3(previous.data)}, true
	}
	old: migrations.Reload_V1
	if decode_json(bytes, &old) && old.version == migrations.V1_VERSION {
		return {version = migrations.V3_VERSION, data = migrations.store_v2_to_v3(migrations.store_v1_to_v2(old.data))}, true
	}
	return {}, false
}

// Decoded slices belong to context.temp_allocator; consume them before its next reset.
// Reject omitted fields, partial arrays and integer overflow before unmarshal can narrow them.
decode_json :: proc(data: []u8, output: ^$T, max_bytes := state.MAX_SAVE_BYTES) -> bool {
	if len(data) == 0 || len(data) > max_bytes {return false}
	// The standard parser recurses without a depth limit. Bound nesting before it allocates or recurses.
	tokenizer := json.make_tokenizer(string(data), spec = .JSON, parse_integers = true)
	depth := 0
	for {
		token, err := json.get_token(&tokenizer)
		if err != nil && err != .EOF {return false}
		if token.kind == .EOF {
			if depth != 0 || token.offset != len(data) {return false}
			break
		}
		#partial switch token.kind {
		case .Open_Brace, .Open_Bracket:
			depth += 1
			if depth > MAX_JSON_DEPTH {return false}
		case .Close_Brace, .Close_Bracket:
			depth -= 1
			if depth < 0 {return false}
		case .Integer:
			// The standard parser wraps overflowing integer literals instead of rejecting them.
			digits := token.text
			limit := "9223372036854775807"
			if digits[0] == '-' {digits = digits[1:]; limit = "9223372036854775808"}
			if len(digits) > len(limit) || (len(digits) == len(limit) && digits > limit) {return false}
		}
	}
	parser := json.make_parser(data, spec = .JSON, parse_integers = true, allocator = context.temp_allocator)
	value, err := json.parse_value(&parser)
	if err != nil || parser.curr_token.kind != .EOF || !matches(value, type_info_of(T)) {return false}
	return json.unmarshal(data, output, spec = .JSON, allocator = context.temp_allocator) == nil
}

// ---------------- File ----------------

@(private = "file")
matches :: proc(value: json.Value, ti: ^reflect.Type_Info) -> bool {
	base := reflect.type_info_base(ti)
	#partial switch info in base.variant {
	case reflect.Type_Info_Struct:
		object, ok := value.(json.Object)
		if !ok || len(object) != int(info.field_count) {return false}
		for i in 0..<info.field_count {
			field, found := object[info.names[i]]
			if !found || !matches(field, info.types[i]) {return false}
		}
		return true
	case reflect.Type_Info_Array:
		array, ok := value.(json.Array)
		if !ok || len(array) != info.count {return false}
		for item in array {if !matches(item, info.elem) {return false}}
		return true
	case reflect.Type_Info_Slice:
		array, ok := value.(json.Array)
		if !ok {return false}
		for item in array {if !matches(item, info.elem) {return false}}
		return true
	case reflect.Type_Info_Boolean:
		_, ok := value.(json.Boolean)
		return ok
	case reflect.Type_Info_String:
		_, ok := value.(json.String)
		return ok
	case reflect.Type_Info_Integer:
		number, ok := value.(json.Integer)
		if !ok {return false}
		// Equally wide destinations need only a sign check; a 64-bit shift would overflow.
		if base.size >= size_of(json.Integer) {return info.signed || number >= 0}
		bits := u32(base.size * 8)
		if info.signed {
			limit := json.Integer(1) << (bits - 1)
			return number >= -limit && number < limit
		}
		return number >= 0 && number < json.Integer(1) << bits
	case reflect.Type_Info_Enum:
		number, ok := value.(json.Integer)
		if !ok {return false}
		for allowed in info.values {if number == json.Integer(allowed) {return true}}
	case reflect.Type_Info_Bit_Set:
		number, ok := value.(json.Integer)
		if !ok || number < 0 {return false}
		mask := (json.Integer(1) << u32(info.upper - info.lower + 1)) - 1
		return number & ~mask == 0
	case reflect.Type_Info_Float:
		#partial switch number in value {
		case json.Integer: return true
		case json.Float: return !math.is_nan(number) && !math.is_inf(number) &&
			(base.size == 8 || abs(number) <= f64(max(f32)))
		}
	}
	return false
}
