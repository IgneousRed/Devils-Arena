#+test
#+build !js
#+private file
package effects

// -------------------------------- Imports --------------------------------

// ---------------- Odin ----------------

import "core:os"
import "core:testing"

// -------------------------------- Procedures --------------------------------

// ---------------- File ----------------

// The lint command runs this executable in an isolated temporary working directory.
@(test)
native_storage_locations_preserve_legacy_input :: proc(t: ^testing.T) {
	if os.exists(".git") || os.exists("flake.nix") || os.exists(".local") || os.exists("binaries/save.json") {
		testing.expect(t, false, "Storage tests require an isolated empty working directory; existing data was left untouched")
		return
	}
	os.make_directory("binaries")
	testing.expect(t, os.write_entire_file("binaries/save.json", "legacy input") == nil)
	bytes, ok := read_save()
	testing.expect(t, ok && string(bytes) == "legacy input")
	testing.expect(t, write_save(transmute([]u8)string("new input")))
	bytes, ok = read_save()
	testing.expect(t, ok && string(bytes) == "new input")
	testing.expect(t, os.exists("binaries/save.json"), "Saving must not delete the original legacy file")
	testing.expect(t, !os.exists(SAVE_PATH + ".next"), "Successful save atomically publishes the temporary file")
	recording_begin()
	recording_emit(transmute([]u8)string("captured input"))
	recording_finish()
	files, directory_error := os.read_directory_by_path(".local/recordings", -1, context.temp_allocator)
	testing.expect(t, directory_error == nil && len(files) == 1 && !os.exists("binaries/recordings"))
	if len(files) == 1 {
		captured, read_error := os.read_entire_file(files[0].fullpath, context.temp_allocator)
		testing.expect(t, read_error == nil && string(captured) == "captured input\n")
	}
}
