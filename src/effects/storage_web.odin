#+build js
#+private
package effects

// -------------------------------- Imports --------------------------------

// ---------------- Project ----------------

import "../state"

// -------------------------------- Procedures --------------------------------

// ---------------- Package ----------------

recording_begin :: proc() {}

recording_emit :: proc(bytes: []u8) {devil_record(raw_data(bytes), i32(len(bytes)))}

recording_finish :: proc() {}

write_save :: proc(bytes: []u8) -> bool {
	return devil_save(raw_data(bytes), i32(len(bytes))) == 1
}

read_save :: proc() -> (bytes: []u8, ok: bool) {
	bytes = make([]u8, state.MAX_SAVE_BYTES, context.temp_allocator)
	size := devil_load(raw_data(bytes), i32(len(bytes)))
	if size <= 0 || size > i32(len(bytes)) {return nil, false}
	return bytes[:size], true
}
