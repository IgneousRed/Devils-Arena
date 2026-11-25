#+build !js
#+private
package effects

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:os"
import "core:fmt"
import "core:time"

// ---------------- Project ----------------

import "../state"

// -------------------------------- Globals --------------------------------

// ---------------- File ----------------

// Recorder output is a boundary resource, separate from live game facts and saves.
@(private = "file")
recording_file: ^os.File

@(private = "file")
recording_bytes: int

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

recording_begin :: proc() {
	os.make_directory(".local")
	os.make_directory(".local/recordings")
	path := fmt.tprintf(".local/recordings/%d.jsonl", time.to_unix_nanoseconds(time.now()))
	file, err := os.open(path, os.O_CREATE | os.O_EXCL | os.O_WRONLY)
	if err != nil {fmt.eprintln("Could not open input recording:", err); return}
	recording_file = file
	recording_bytes = 0
	fmt.println("Input recording:", path)
}

recording_emit :: proc(bytes: []u8) {
	if recording_file == nil {return}
	if len(bytes) >= state.MAX_RECORDING_BYTES - recording_bytes {
		fmt.eprintln("Input recording reached 64 MiB; stopped recording and retained the captured prefix.")
		recording_finish()
		return
	}
	count, err := os.write(recording_file, bytes)
	if err != nil || count != len(bytes) {fmt.eprintln("Input recording write failed:", err); recording_finish(); return}
	count, err = os.write(recording_file, []u8{10})
	if err != nil || count != 1 {fmt.eprintln("Input recording newline failed:", err); recording_finish()}
	recording_bytes += len(bytes) + 1
}

recording_finish :: proc() {
	if recording_file != nil {os.close(recording_file); recording_file = nil}
}

write_save :: proc(bytes: []u8) -> bool {
	os.make_directory(".local")
	os.make_directory(".local/data")
	temporary := SAVE_PATH + ".next"
	if os.write_entire_file(temporary, bytes) != nil {return false}
	return os.rename(temporary, SAVE_PATH) == nil
}

read_save :: proc() -> (bytes: []u8, ok: bool) {
	// Existing installations remain readable until their next successful save.
	path := SAVE_PATH if os.exists(SAVE_PATH) else "binaries/save.json"
	file, open_error := os.open(path)
	if open_error != nil {return nil, false}
	defer os.close(file)
	size, err := os.file_size(file)
	if err != nil || size <= 0 || size > state.MAX_SAVE_BYTES {return nil, false}
	bytes = make([]u8, int(size), context.temp_allocator)
	count, read_error := os.read_full(file, bytes)
	return bytes, read_error == nil && count == len(bytes)
}
