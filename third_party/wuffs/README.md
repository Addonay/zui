# Wuffs

Vendored from Wuffs, commit b36a81d (https://github.com/google/wuffs), file
`release/c/wuffs-v0.4.c` (version string `0.4.0-alpha.12`). License: Apache-2.0 OR MIT, see `LICENSE`.

- `wuffs-v0.4.c`: the single-file library. Only the codecs in `zui_wuffs.c` are compiled, through
  `WUFFS_CONFIG__MODULES`.
- `zui_wuffs.c`: a thin C shim over the decoders, used by `src/wuffs.zig`. Built as its own static library
  (see `build.zig`), optimized even in Debug.

To update, replace `wuffs-v0.4.c` with a newer file from `release/c/`, and rebuild the tests.
