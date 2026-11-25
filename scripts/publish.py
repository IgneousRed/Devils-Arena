#!/usr/bin/env python3
"""Publish a complete build directory without exposing partially copied assets."""
import ctypes
import os
from pathlib import Path
import sys


def publish(stage, output):
    stage, output = Path(stage), Path(output)
    if not output.exists():
        stage.rename(output)
        return
    if not output.is_dir() or output.is_symlink():
        raise ValueError(f'Build output must be a directory: {output}')
    # Both platforms atomically exchange existing directories. On success the
    # caller's stage path holds the old build; on failure both paths stay intact.
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        exchange = libc.renamex_np
        exchange.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = exchange(os.fsencode(stage), os.fsencode(output), 2)  # RENAME_SWAP
    elif sys.platform.startswith('linux'):
        exchange = libc.renameat2
        exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = exchange(-100, os.fsencode(stage), -100, os.fsencode(output), 2)  # AT_FDCWD, RENAME_EXCHANGE
    else:
        raise OSError('Atomic build replacement is supported on macOS and Linux; previous output retained')
    if result:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(output))


if __name__ == '__main__':
    publish(*sys.argv[1:])
