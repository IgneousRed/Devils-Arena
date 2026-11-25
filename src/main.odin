#+build !js
package src

// -------------------------------- Imports --------------------------------

// ---------------- Vendor ----------------

import rl "vendor:raylib"

// ---------------- Odin ----------------

import "core:fmt"
import "core:os"

// ---------------- Project ----------------

import "effects"
import "engine"
import "functions"
import "state"

// -------------------------------- Constants --------------------------------

// ---------------- File ----------------

@(private = "file")
TARGET_FPS :: 60

// -------------------------------- Procedures --------------------------------

// ---------------- Public ----------------

main :: proc() {
	init_game()
	rl.SetTargetFPS(TARGET_FPS)
	if len(os.args) == 3 && os.args[1] == "--replay" {
		file, open_error := os.open(os.args[2])
		if open_error != nil {panic("Could not open input recording")}
		defer os.close(file)
		size, size_error := os.file_size(file)
		if size_error != nil || size <= 0 || size > state.MAX_RECORDING_BYTES {panic("Recording must contain at most 64 MiB")}
		bytes := make([]u8, int(size), context.allocator)
		defer delete(bytes)
		count, read_error := os.read_full(file, bytes)
		if read_error != nil || count != len(bytes) {panic("Could not read complete input recording")}
		lines := functions.recording_lines(bytes)
		defer delete(lines)
		header: state.Recording_Header
		if len(lines) < 1 || !functions.decode_json(transmute([]u8)lines[0], &header, len(bytes)) ||
		   state.APPLICATION_VERSION == "unversioned" || header.format != 1 || header.build != state.APPLICATION_VERSION || header.initial.version != state.RELOAD_VERSION {
			panic("Recording belongs to another application version or is invalid")
		}
		tx := engine.begin()
		tx.data = header.initial.data
		if !engine.commit(&tx) {panic("Invalid recording initial state")}
		end: state.Recording_End
		complete := functions.decode_json(transmute([]u8)lines[len(lines) - 1], &end, len(bytes))
		last := len(lines)
		if complete {
			if end.final.version != state.RELOAD_VERSION {panic("Invalid recording footer")}
			last -= 1
		} else {fmt.eprintln("Incomplete recording: replaying captured inputs without final-state verification.")}
		cancelled := false
		for index := 1; index < last; index += 1 {
			if rl.WindowShouldClose() {cancelled = true; break}
			event: state.Recording_Event
			if !functions.decode_json(transmute([]u8)lines[index], &event, len(bytes)) {panic("Invalid recording event")}
			switch event.kind {
			case .Frame:
				if index + 1 < last {
					next: state.Recording_Event
					if !functions.decode_json(transmute([]u8)lines[index + 1], &next, len(bytes)) {panic("Invalid recording event")}
					if next.kind == .Storage {event.storage = next.storage; index += 1}
				}
				if !functions.valid_frame_input(event.frame) {panic("Invalid recorded frame")}
				if event.frame.width != rl.GetScreenWidth() || event.frame.height != rl.GetScreenHeight() {rl.SetWindowSize(event.frame.width, event.frame.height)}
				update_game(event.frame, event.storage, true)
			case .Restore: effects.restore(event.data, true)
			case .Storage: panic("Orphaned storage result")
			}
		}
		if complete && !cancelled && end.final.data != engine.begin().data {panic("Recording diverged")}
	} else {
		effects.record_start()
		for {
			input := sample_frame(1, -rl.GetMouseWheelMove() * SCROLL_PIXELS)
			input.close = rl.WindowShouldClose()
			if input.close {effects.record_event({kind = .Frame, frame = input}); break}
			update_game(input)
		}
		effects.record_end()
	}
	rl.UnloadFont(app_font)
	rl.CloseWindow()
}
