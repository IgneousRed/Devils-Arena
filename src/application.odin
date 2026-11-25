#+private file
package src

// -------------------------------- Imports --------------------------------

// ---------------- Vendor ----------------

import rl "vendor:raylib"
import gl "vendor:raylib/rlgl"

// ---------------- Odin ----------------

import "core:fmt"
import "core:math"

// ---------------- Project ----------------

import "catalog"
import "effects"
import "engine"
import "functions"
import imui "odin_ui:raylib"
import "state"

// -------------------------------- Constants --------------------------------

// ---------------- Package ----------------

@(private = "package")
SCROLL_PIXELS :: f32(30)

// ---------------- File ----------------

INITIAL_WIDTH :: 960

INITIAL_HEIGHT :: 800

FONT_SIZE :: 48

MAX_FRAME_SECONDS :: f64(0.1)

FONT_DATA :: #load("../assets/AtkinsonHyperlegibleNext-SemiBold.ttf", []u8)

BACKGROUND :: rl.Color{19, 16, 22, 255}

PANEL :: rl.Color{32, 26, 36, 255}

CONTROL :: rl.Color{51, 40, 55, 255}

ACCENT :: rl.Color{123, 49, 65, 255}

INK :: rl.Color{239, 228, 214, 255}

MUTED :: rl.Color{180, 163, 170, 255}

TEXT_SIZE :: f32(18)

TITLE_SIZE :: f32(30)

PADDING :: f32(16)

GAP :: f32(12)

CORNER_RADIUS :: f32(6)

ARENA_HEIGHT :: f32(400)

SPELL_SIDEBAR_WIDTH :: f32(210)

WIDE_ARENA_WIDTH :: f32(650)

ARENA_MARKER_COUNT :: 16

LAVA_COLOR :: rl.Color{96, 36, 38, 255}

LAVA_EDGE_COLOR :: rl.Color{224, 99, 57, 255}

ARENA_COLOR :: rl.Color{49, 47, 55, 255}

ARENA_GUIDE_COLOR :: rl.Color{66, 61, 71, 255}

ARENA_MARKER_COLOR :: rl.Color{133, 101, 87, 255}

AIM_COLOR :: rl.Color{107, 116, 138, 255}

LIGHTNING_EDGE_COLOR :: rl.Color{63, 105, 149, 255}

METEOR_WARNING_COLOR :: rl.Color{128, 62, 60, 255}

PLAYER_COLOR :: rl.Color{121, 182, 230, 255}

DUMMY_COLOR :: rl.Color{220, 127, 107, 255}

BODY_SHADOW_COLOR :: rl.Color{20, 18, 24, 160}

BODY_OUTLINE_COLOR :: rl.Color{26, 23, 33, 255}

BODY_FACE_COLOR :: rl.Color{38, 32, 45, 255}

STAFF_COLOR :: rl.Color{172, 145, 114, 255}

INPUT_KEYS :: [state.Input_Key]rl.KeyboardKey{
	.W = .W, .A = .A, .S = .S, .D = .D, .Q = .Q, .E = .E, .R = .R, .F = .F, .Space = .SPACE,
	.Left_Control = .LEFT_CONTROL, .Right_Control = .RIGHT_CONTROL, .Left_Super = .LEFT_SUPER,
	.Right_Super = .RIGHT_SUPER, .Left_Alt = .LEFT_ALT, .Right_Alt = .RIGHT_ALT,
}

// -------------------------------- Globals --------------------------------

// ---------------- Package ----------------

// GPU resources are reconstructed on startup and never saved as authoritative facts.
@(private = "package")
app_font: rl.Font

// ---------------- File ----------------

@(rodata)
NOTICE_TEXT := [state.Notice]string{
	.None = "",
	.Saved = "Game saved.",
	.Loaded = "Save loaded.",
	.Reset = "Items and battle reset.",
	.Invalid_Data = "Unable to load or apply invalid data. Current state retained.",
	.Storage_Error = "Unable to save. Storage is unavailable or full.",
	.Rules_Undefined = "Combat paused: a zero-stat ratio needs a rule. Progress is retained; restart restores base stats.",
}

@(rodata)
SPELL_BINDINGS := [catalog.Spell]Spell_Binding{
	.None = {},
	.Fireball = {.Q, "Q"}, .Lightning = {.E, "E"}, .Meteor = {.R, "R"},
	.Teleport = {.F, "F"}, .Swap = {.Space, "Space"},
}

@(rodata)
SPELL_COLORS := [catalog.Spell]rl.Color{
	.None = MUTED,
	.Fireball = {255, 152, 75, 255},
	.Lightning = {132, 211, 255, 255},
	.Meteor = {249, 99, 91, 255},
	.Teleport = {156, 149, 255, 255},
	.Swap = {112, 226, 189, 255},
}

// Runtime clock only schedules simulation; committed battle state contains whole ticks.
tick_accumulator: f64

// -------------------------------- Types --------------------------------

// ---------------- Package ----------------

@(private = "package")
Frame :: struct {
	layout: imui.UI,
	buttons: [dynamic]Button,
	body: int,
	arena: int,
}

// ---------------- File ----------------

Button :: struct {node: int, command: state.Command}

Spell_Binding :: struct {key: state.Input_Key, label: string}

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

@(private = "package")
init_game :: proc() {
	rl.SetConfigFlags({.MSAA_4X_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(INITIAL_WIDTH, INITIAL_HEIGHT, catalog.GAME_TITLE)
	rl.SetExitKey(.KEY_NULL)
	app_font = rl.LoadFontFromMemory(".ttf", raw_data(FONT_DATA), i32(len(FONT_DATA)), FONT_SIZE, nil, 0)
	rl.SetTextureFilter(app_font.texture, .BILINEAR)
	tx := engine.begin()
	if !engine.commit(&tx) {panic("Initial state is invalid")}
}

@(private = "package")
sample_frame :: proc(pixel_ratio, scroll: f32) -> state.Frame_Input {
	mouse := rl.GetMousePosition()
	input := state.Frame_Input{
		width = rl.GetScreenWidth(), height = rl.GetScreenHeight(), pixel_ratio = pixel_ratio, scroll = scroll,
		mouse_x = mouse.x, mouse_y = mouse.y, seconds = f64(rl.GetFrameTime()), focused = rl.IsWindowFocused(),
		left_pressed = rl.IsMouseButtonPressed(.LEFT), save_pressed = rl.IsKeyPressed(.F5), load_pressed = rl.IsKeyPressed(.F9),
	}
	for key, name in INPUT_KEYS {if rl.IsKeyDown(key) {input.keys += {name}}}
	return input
}

@(private = "package")
update_game :: proc(sample: state.Frame_Input, storage_input: state.Storage_Result = {}, replay := false, draw := true) {
	defer free_all(context.temp_allocator)
	storage := storage_input
	if !replay {effects.record_event({kind = .Frame, frame = sample})}
	if sample.close {return}
	pixel_ratio, scroll_delta := sample.pixel_ratio, sample.scroll
	width := f32(sample.width) / pixel_ratio
	height := f32(sample.height) / pixel_ratio
	mouse := rl.Vector2{sample.mouse_x, sample.mouse_y} / pixel_ratio
	focused := sample.focused
	tx := engine.begin()
	frame: Frame
	compose(&frame, tx.data, width, height)
	composed_revision := tx.revision
	// Resolve the whole frame's input against the same starting layout and facts.
	input: state.Battle_Input
	if frame.arena >= 0 {
		center, scale := arena_geometry(&frame)
		if !(scale <= 0) {
			player := tx.data.facts.bodies[0]
			input = state.Battle_Input{aim_x = player.x + f64((mouse.x - center.x) / scale), aim_y = player.y + f64((mouse.y - center.y) / scale)}
			if .W in sample.keys {input.move_y -= 1}
			if .S in sample.keys {input.move_y += 1}
			if .A in sample.keys {input.move_x -= 1}
			if .D in sample.keys {input.move_x += 1}
			if imui.contains(&frame.layout, frame.arena, mouse) {
				for binding, spell in SPELL_BINDINGS {
					if spell != .None && binding.key in sample.keys {input.casts += {spell}}
				}
			}
		}
	}
	command: state.Command
	shortcut_modifier := sample.keys & {.Left_Control, .Right_Control, .Left_Super, .Right_Super, .Left_Alt, .Right_Alt} != {}
	if !shortcut_modifier {
		if sample.save_pressed {command = {kind = .Save}}
		if sample.load_pressed {command = {kind = .Load}}
	}
	if sample.left_pressed {
		command = {}
		for button in frame.buttons {
			if imui.contains(&frame.layout, button.node, mouse) {command = button.command; break}
		}
	}
	if command.kind == .None && scroll_delta != 0 {
		maximum := frame.layout.nodes[frame.body].max_scroll
		command = {kind = .Scroll, scroll = clamp(min(tx.data.ui.scroll, maximum) + scroll_delta, 0, maximum)}
	}
	if command.kind != .None {
		if effects.execute(command, &storage, replay) {
			#partial switch command.kind {
			case .Reset, .Load, .Start_Battle, .Restart_Battle, .Pick_Items:
				tick_accumulator = 0
				input = {}
			}
		}
		tx = engine.begin()
	}
	if shortcut_modifier || !focused {input = {}}
	if tx.data.facts.battle.phase == .Active && focused {
		// Cap catch-up work after a suspended tab; never advance combat while it is hidden.
		tick_accumulator += min(sample.seconds, MAX_FRAME_SECONDS) * f64(catalog.SIMULATION_SPEEDS[tx.data.facts.session.speed_index])
		ticks := int(tick_accumulator / catalog.TICK_SECONDS)
		for _ in 0..<ticks {
			if !effects.tick(input) {break}
		}
		tick_accumulator -= f64(ticks) * catalog.TICK_SECONDS
	} else {tick_accumulator = 0}
	if !draw {return}
	tx = engine.begin()
	if tx.revision != composed_revision {compose(&frame, tx.data, width, height)}
	rl.BeginDrawing()
	rl.ClearBackground(BACKGROUND)
	gl.PushMatrix()
	gl.Scalef(pixel_ratio, pixel_ratio, 1)
	imui.draw(&frame.layout, pixel_ratio)
	if imui.begin_clip(&frame.layout, frame.arena, pixel_ratio) {
		facts := tx.data.facts
		defer rl.EndScissorMode()
		origin, scale := arena_geometry(&frame)
		center := origin - rl.Vector2{f32(facts.bodies[0].x), f32(facts.bodies[0].y)} * scale
		radius := f32(functions.arena_radius(facts.battle.ticks)) * scale
		rect := frame.layout.nodes[frame.arena].rect
		rl.DrawRectangleV({rect.x, rect.y}, {rect.width, rect.height}, LAVA_COLOR)
		rl.DrawCircleV(center, radius + 9 * scale, LAVA_EDGE_COLOR)
		rl.DrawCircleV(center, radius, ARENA_COLOR)
		rl.DrawCircleLinesV(center, radius * 0.65, ARENA_GUIDE_COLOR)
		rl.DrawCircleLinesV(center, radius * 0.3, ARENA_GUIDE_COLOR)
		for i in 0..<ARENA_MARKER_COUNT {
			angle := f32(i) * 2 * math.PI / ARENA_MARKER_COUNT
			point := center + rl.Vector2{math.cos(angle), math.sin(angle)} * (radius - 16 * scale)
			rl.DrawCircleV(point, 3 * scale, ARENA_MARKER_COLOR)
		}
		if facts.battle.phase == .Active && imui.contains(&frame.layout, frame.arena, mouse) {
			dx, dy := functions.direction(f64(mouse.x - origin.x), f64(mouse.y - origin.y))
			rl.DrawLineEx(origin, origin + rl.Vector2{f32(dx), f32(dy)} * 90 * scale, 1, AIM_COLOR)
			rl.DrawCircleLinesV(mouse, 7, INK)
			rl.DrawLineEx(mouse - {10, 0}, mouse + {10, 0}, 1, INK)
			rl.DrawLineEx(mouse - {0, 10}, mouse + {0, 10}, 1, INK)
		}
		for spell in facts.spells {
			if spell.spell == .None {continue}
			point := center + rl.Vector2{f32(spell.x), f32(spell.y)} * scale
			color := SPELL_COLORS[spell.spell]
			definition := catalog.SPELLS[spell.spell]
			switch spell.spell {
			case .Fireball, .Swap:
				dx, dy := functions.direction(spell.vx, spell.vy)
				rl.DrawLineEx(point, point - rl.Vector2{f32(dx), f32(dy)} * 35 * scale, 8 * scale, color)
				rl.DrawCircleV(point, f32(definition.radius) * scale, color)
				rl.DrawCircleV(point, 5 * scale, INK)
			case .Lightning:
				end := point + rl.Vector2{f32(spell.vx), f32(spell.vy)} * scale
				rl.DrawLineEx(point, end, 10 * scale, LIGHTNING_EDGE_COLOR)
				rl.DrawLineEx(point, end, 3 * scale, color)
			case .Meteor:
				blast := f32(definition.radius) * scale
				rl.DrawCircleLinesV(point, blast, color)
				if spell.remaining <= catalog.METEOR_FLASH_SECONDS {rl.DrawCircleV(point, blast, color)}
				else {rl.DrawCircleV(point, blast * f32(1 - spell.remaining / definition.lifetime), METEOR_WARNING_COLOR)}
			case .Teleport:
				rl.DrawCircleLinesV(point, 42 * scale * f32(spell.remaining / definition.lifetime), color)
			case .None:
			}
		}
		for body, id in facts.bodies {
			point := center + rl.Vector2{f32(body.x), f32(body.y)} * scale
			color := PLAYER_COLOR if id == 0 else DUMMY_COLOR
			rl.DrawEllipse(i32(point.x), i32(point.y + 18 * scale), 24 * scale, 10 * scale, BODY_SHADOW_COLOR)
			rl.DrawCircleV(point, 24 * scale, BODY_OUTLINE_COLOR)
			rl.DrawTriangle(point + {0, -28 * scale}, point + {-19 * scale, 17 * scale}, point + {19 * scale, 17 * scale}, color)
			rl.DrawCircleV(point + {0, -2 * scale}, 10 * scale, BODY_FACE_COLOR)
			rl.DrawCircleV(point + {-4 * scale, -2 * scale}, 2 * scale, INK)
			rl.DrawCircleV(point + {4 * scale, -2 * scale}, 2 * scale, INK)
			rl.DrawLineEx(point + {23 * scale, -19 * scale}, point + {23 * scale, 23 * scale}, 3 * scale, STAFF_COLOR)
			rl.DrawCircleV(point + {23 * scale, -22 * scale}, 5 * scale, color)
			health := f32(facts.combatants[id].health / body.starting_health)
			rl.DrawRectangleV(point + {-30 * scale, -43 * scale}, {60 * scale, 5 * scale}, CONTROL)
			rl.DrawRectangleV(point + {-30 * scale, -43 * scale}, {60 * scale * clamp(health, 0, 1), 5 * scale}, color)
		}
	}
	gl.PopMatrix()
	rl.EndDrawing()
}

@(private = "package")
compose :: proc(frame: ^Frame, data: state.Store, width, height: f32) {
	frame.buttons = make([dynamic]Button, context.temp_allocator)
	view := functions.overview(data.facts, data.ui)
	imui.begin(&frame.layout, width, height, {direction = .vertical, padding = {PADDING, PADDING, PADDING, PADDING}, gap = GAP}, storage = frame.layout.nodes)
	frame.body = imui.column(&frame.layout, {
		width = imui.grow(), height = imui.grow(), gap = GAP,
		padding = {PADDING, PADDING, PADDING, PADDING},
		background = PANEL, radius = CORNER_RADIUS,
		scroll = true, scroll_offset = data.ui.scroll, scroll_color = MUTED,
		alignment = {horizontal = .stretch, vertical = .start},
	})
	imui.paragraph(&frame.layout, app_font, catalog.GAME_TITLE, TITLE_SIZE, INK)
	imui.paragraph(&frame.layout, app_font, "Warlock-inspired spell practice / Player vs Dummy", TEXT_SIZE, MUTED)
	imui.row(&frame.layout, {gap = GAP})
	button(frame, "Save", {kind = .Save})
	button(frame, "Load", {kind = .Load})
	button(frame, "Reset", {kind = .Reset})
	imui.close(&frame.layout)
	if data.notice != .None {imui.paragraph(&frame.layout, app_font, NOTICE_TEXT[data.notice], TEXT_SIZE, MUTED)}
	{
		facts := data.facts
		panel_width := max(1, width - PADDING * 4)
		frame.arena = -1
		if facts.battle.phase == .Picking {
			imui.paragraph(&frame.layout, app_font, "CHOOSE YOUR SPELL ITEMS", TEXT_SIZE, INK)
			imui.paragraph(&frame.layout, app_font, "Each item grants one spell. Pick any or all five, then enter the arena.", TEXT_SIZE, MUTED)
			for spell in catalog.Spell.Fireball..=catalog.Spell.Swap {
				definition := catalog.SPELLS[spell]
				owned := functions.item_slot(facts.items[0], spell) >= 0
				imui.column(&frame.layout, {width = imui.grow(), gap = GAP / 2, padding = {GAP, GAP, GAP, GAP}, background = CONTROL, radius = CORNER_RADIUS})
				imui.paragraph(&frame.layout, app_font, fmt.tprintf("%s  /  %s [%s]", definition.item, definition.name, SPELL_BINDINGS[spell].label), TEXT_SIZE, SPELL_COLORS[spell])
				imui.paragraph(&frame.layout, app_font, definition.description, TEXT_SIZE, MUTED)
				if functions.item_slot(facts.items[1], spell) >= 0 {
					imui.paragraph(&frame.layout, app_font, fmt.tprintf("Owned by %s", catalog.COMBATANT_NAMES[1]), TEXT_SIZE, MUTED)
				} else {button(frame, "Picked" if owned else "Pick item", {kind = .Pick, spell = spell}, owned)}
				imui.close(&frame.layout)
			}
			if functions.has_items(facts.items[0]) {
				button(frame, "Enter arena", {kind = .Start_Battle}, true)
			} else {
				imui.paragraph(&frame.layout, app_font, "Pick at least one item to enter the arena.", TEXT_SIZE, MUTED)
			}
		} else {
			phase := "PRACTICE BATTLE"
			switch facts.battle.phase {
			case .Picking, .Active:
			case .Player_Won: phase = "YOU WIN"
			case .Dummy_Won: phase = "DUMMY WINS"
			case .Draw: phase = "DRAW"
			}
			imui.paragraph(&frame.layout, app_font, fmt.tprintf("%s  /  %.1fs remaining", phase,
				f64(catalog.BATTLE_TICKS - facts.battle.ticks) * catalog.TICK_SECONDS), TEXT_SIZE, INK)
			for name, id in catalog.COMBATANT_NAMES {
				stats := facts.combatants[id]
				imui.paragraph(&frame.layout, app_font, fmt.tprintf("%s: %.4g HP / %.4g Armor / Lava exposure: %.2fs",
					name, stats.health, stats.armor, f64(facts.bodies[id].lava_ticks) * catalog.TICK_SECONDS), TEXT_SIZE, MUTED)
			}
			wide := panel_width >= WIDE_ARENA_WIDTH
			if wide {imui.row(&frame.layout, {width = imui.grow(), gap = GAP})}
			frame.arena = imui.column(&frame.layout, {width = imui.grow(), height = imui.fixed(min(ARENA_HEIGHT, panel_width)), background = BACKGROUND})
			imui.close(&frame.layout)
			if wide {imui.column(&frame.layout, {width = imui.fixed(SPELL_SIDEBAR_WIDTH), gap = GAP})}
			imui.paragraph(&frame.layout, app_font, "WASD move / Mouse aim / Point over the arena view and hold spell keys to cast / Arena shrinks", TEXT_SIZE, MUTED)
			for spell, slot in facts.items[0] {
				if spell == .None {continue}
				definition := catalog.SPELLS[spell]
				cooldown := facts.cooldowns[0][slot]
				label := fmt.tprintf("[%s] %s  /  %.1fs", SPELL_BINDINGS[spell].label, definition.name, cooldown) if cooldown > 0 else
					fmt.tprintf("[%s] %s  /  Ready", SPELL_BINDINGS[spell].label, definition.name)
				imui.paragraph(&frame.layout, app_font, label, TEXT_SIZE, MUTED if cooldown > 0 else SPELL_COLORS[spell])
			}
			if !wide {imui.row(&frame.layout, {gap = GAP})}
			button(frame, "Restart battle", {kind = .Restart_Battle})
			button(frame, "Pick items", {kind = .Pick_Items})
			imui.close(&frame.layout)
			if wide {imui.close(&frame.layout)}
		}
	}
	imui.separator(&frame.layout, CONTROL)
	imui.paragraph(&frame.layout, app_font, "STATE INSPECTOR", TEXT_SIZE, MUTED)
	imui.row(&frame.layout, {gap = GAP})
	for name, id in catalog.COMBATANT_NAMES {
		button(frame, name, {kind = .Select, combatant = i32(id)}, view.selected == i32(id))
	}
	imui.close(&frame.layout)
	for name, id in catalog.STAT_NAMES {metric(frame, name, fmt.tprintf("%.4g", view.stats[id]))}
	metric(frame, "Critical chance", rate_label(view.critical_chance, view.critical_defined))
	metric(frame, "Dodge chance", rate_label(view.dodge_chance, view.dodge_defined))
	metric(frame, "Cooldown rate", rate_label(view.cooldown_rate, view.cooldown_defined))
	imui.paragraph(&frame.layout, app_font,
		"Power effects are pending. Critical doubles spell stat changes. Dodge cancels noncritical enemy spells; critical and dodge cancel each other. Cooldown rate affects spell recovery, not movement.",
		TEXT_SIZE, MUTED)
	imui.paragraph(&frame.layout, app_font, "Retained activity: practice battles do not update these counters.", TEXT_SIZE, MUTED)
	metric(frame, "Dodges", fmt.tprintf("%d", view.activity.dodges))
	metric(frame, "Misses", fmt.tprintf("%d", view.activity.misses))
	metric(frame, "Move progress", fmt.tprintf("%.4g", view.activity.move_progress))
	imui.separator(&frame.layout, CONTROL)
	metric(frame, "Kills", fmt.tprintf("%d", view.kills))
	button(frame, fmt.tprintf("Simulation speed: %dx", view.simulation_speed), {kind = .Cycle_Speed})
	imui.close(&frame.layout)
	if imui.finish(&frame.layout) != nil {panic("UI layout failed")}
}

// ---------------- File ----------------

metric :: proc(frame: ^Frame, name, value: string) {
	imui.row(&frame.layout, {width = imui.grow(), gap = GAP})
	imui.paragraph(&frame.layout, app_font, name, TEXT_SIZE, MUTED)
	imui.paragraph(&frame.layout, app_font, value, TEXT_SIZE, INK, width = nil)
	imui.close(&frame.layout)
}

rate_label :: proc(value: f64, defined: bool) -> string {
	return fmt.tprintf("%.1f%%", value * 100) if defined else "Rule pending"
}

arena_geometry :: proc(frame: ^Frame) -> (center: rl.Vector2, scale: f32) {
	rect := frame.layout.nodes[frame.arena].rect
	return {rect.x + rect.width / 2, rect.y + rect.height / 2}, min(rect.width, rect.height) / f32(catalog.WORLD_LIMIT * 2)
}

button :: proc(frame: ^Frame, label: string, command: state.Command, active: bool = false) {
	node := imui.column(&frame.layout, {
		padding = {PADDING, GAP, PADDING, GAP},
		background = ACCENT if active else CONTROL,
		radius = CORNER_RADIUS,
	})
	imui.paragraph(&frame.layout, app_font, label, TEXT_SIZE, INK, width = nil)
	imui.close(&frame.layout)
	append(&frame.buttons, Button{node, command})
}
