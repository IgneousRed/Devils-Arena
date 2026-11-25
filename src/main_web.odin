#+build js
package src

// -------------------------------- Imports --------------------------------

// ---------------- Vendor ----------------

import rl "vendor:raylib"

// ---------------- Odin ----------------

import "base:runtime"
// Used by development-only inspection.
@(require)
import "core:encoding/json"
// Used by development-only inspection.
@(require)
import "core:fmt"
import "core:mem"

// ---------------- Project ----------------

import "effects"
import "engine"
import "functions"
// Used by development-only inspection.
@(require)
import imui "odin_ui:raylib"
import "state"

// -------------------------------- Constants --------------------------------

// ---------------- Public ----------------

when ODIN_OS == .JS {
	WEB_SCRATCH_BYTES :: 8 * mem.Megabyte
}

// -------------------------------- Globals --------------------------------

// ---------------- File ----------------

when ODIN_OS == .JS {
	@(private = "file")
	web_scratch: [WEB_SCRATCH_BYTES]u8
	@(private = "file")
	web_arena: mem.Arena
	@(private = "file")
	web_context: runtime.Context
	@(private = "file")
	reload_buffer: [state.MAX_SAVE_BYTES]u8
	@(private = "file")
	recording_buffer: [state.MAX_SAVE_BYTES * 8]u8
}

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

when ODIN_OS == .JS {
	main :: proc() {}
	@(export)
	web_start :: proc "c" () {
		context = runtime.default_context()
		mem.arena_init(&web_arena, web_scratch[:])
		context.temp_allocator = mem.arena_allocator(&web_arena)
		context.allocator = context.temp_allocator
		web_context = context
		init_game()
		effects.record_start()
	}
}

when ODIN_OS == .JS {
	@(export)
	web_frame :: proc "c" (width, height: i32, ratio, scroll: f32) {
		context = web_context
		if width != rl.GetScreenWidth() || height != rl.GetScreenHeight() {rl.SetWindowSize(width, height)}
		update_game(sample_frame(ratio if ratio > 0 else 1, scroll))
	}
}

when ODIN_OS == .JS {
	@(export)
	web_recording_close :: proc "c" () {
		context = web_context
		rl.UnloadFont(app_font)
		rl.CloseWindow()
	}
	@(export)
	web_recording_buffer :: proc "c" () -> rawptr {return raw_data(recording_buffer[:])}
	@(export)
	web_recording_capacity :: proc "c" () -> i32 {return i32(len(recording_buffer))}
	@(export)
	web_recording_checkpoint :: proc "c" () -> i32 {
		context = web_context
		defer free_all(context.temp_allocator)
		bytes, ok := functions.encode_reload(engine.begin().data)
		if !ok {return 0}
		copy(recording_buffer[:], bytes)
		return i32(len(bytes))
	}
	@(export)
	web_recording_apply :: proc "c" (size: i32, draw: bool) -> bool {
		context = web_context
		defer free_all(context.temp_allocator)
		if size <= 0 || size > len(recording_buffer) {return false}
		event: state.Recording_Event
		if !functions.decode_json(recording_buffer[:size], &event, len(recording_buffer)) {return false}
		switch event.kind {
		case .Frame:
			if !functions.valid_frame_input(event.frame) {return false}
			if draw && (event.frame.width != rl.GetScreenWidth() || event.frame.height != rl.GetScreenHeight()) {rl.SetWindowSize(event.frame.width, event.frame.height)}
			update_game(event.frame, event.storage, true, draw)
		case .Restore: effects.restore(event.data, true)
		case .Storage: return false
		}
		return true
	}
}

when ODIN_OS == .JS && #config(WEB_DEVELOPMENT, false) {
	@(export = #config(WEB_DEVELOPMENT, false))
	web_reload_buffer :: proc "c" () -> rawptr {return raw_data(reload_buffer[:])}
	@(export = #config(WEB_DEVELOPMENT, false))
	web_reload_capacity :: proc "c" () -> i32 {return i32(len(reload_buffer))}
	@(export = #config(WEB_DEVELOPMENT, false))
	web_snapshot :: proc "c" () -> i32 {
		context = web_context
		defer free_all(context.temp_allocator)
		bytes, ok := functions.encode_reload(engine.begin().data)
		if !ok {return 0}
		copy(reload_buffer[:], bytes)
		return i32(len(bytes))
	}
	@(export = #config(WEB_DEVELOPMENT, false))
	web_restore :: proc "c" (size: i32) -> bool {
		context = web_context
		defer free_all(context.temp_allocator)
		if size <= 0 || size > len(reload_buffer) {return false}
		return effects.restore(reload_buffer[:size])
	}
	// Development-only inspection uses the same layout and hit bounds as the renderer.
	@(export = #config(WEB_DEVELOPMENT, false))
	web_controls :: proc "c" (width, height: f32) -> i32 {
		context = web_context
		defer free_all(context.temp_allocator)
		Control_Bounds :: struct {kind: string, combatant: i32, spell: u8, rect, clip: imui.Layout_Rect}
		frame: Frame
		compose(&frame, engine.begin().data, width, height)
		controls := make([dynamic]Control_Bounds, context.temp_allocator)
		for button in frame.buttons {
			node := frame.layout.nodes[button.node]
			append(&controls, Control_Bounds{fmt.tprintf("%v", button.command.kind), button.command.combatant, u8(button.command.spell), node.rect, node.clip})
		}
		if frame.arena >= 0 {
			node := frame.layout.nodes[frame.arena]
			append(&controls, Control_Bounds{kind = "Arena", rect = node.rect, clip = node.clip})
		}
		bytes, err := json.marshal(controls[:], allocator = context.temp_allocator)
		if err != nil || len(bytes) > len(reload_buffer) {return 0}
		copy(reload_buffer[:], bytes)
		return i32(len(bytes))
	}
}
