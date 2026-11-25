// Storage keys remain stable across project renames to preserve existing player saves.
mergeInto(LibraryManager.library, {
  devil_record: function (pointer, length) {
    window.devilRecording.capture(new TextDecoder().decode(HEAPU8.subarray(pointer, pointer + length)));
  },
  devil_save: function (pointer, length) {
    try {
      localStorage.setItem('devils-due.save', new TextDecoder().decode(HEAPU8.subarray(pointer, pointer + length)));
      return 1;
    } catch (_) { return 0; }
  },
  devil_load: function (pointer, capacity) {
    try {
      const value = localStorage.getItem('devils-due.save');
      if (value === null) return 0;
      const bytes = new TextEncoder().encode(value);
      if (bytes.length > capacity) return -1;
      HEAPU8.set(bytes, pointer);
      return bytes.length;
    } catch (_) { return -1; }
  }
});
