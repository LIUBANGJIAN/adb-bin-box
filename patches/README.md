# patches/

Per-tool source patches. A tool (or dep) opts into patches by listing file
names in its manifest entry, e.g.:

```yaml
  patches:
    - strace-musl-syscall.patch
```

The build engine applies every listed patch to the *unpacked source tree*
(`$SRC_DIR`) with `patch -p1 < patches/<name>` **before** `configure` runs.

## Conventions

- File name: `<tool>-<reason>.patch`.
- Context format unified diff (`diff -u` / `git format-patch`), applies with `-p1`.
- One patch = one concern; keep them small and documented in the header.

## Current status

Three patches are currently in use (each `tools.yml` entry lists its own):

- `stress-ng-arch-typo.patch` — upstream's `core-helper.c` calls
  `stress_get_arch()`, but the real function is `stress_arch_get()`; the broken
  call sites only compile in our cross build, so fix the word order.
- `stress-ng-linker-muldefs.patch` — the Makefile's `STATIC=1` LDFLAGS uses the
  GNU-ld-only `-z muldefs` behind an `override`; zig's cc driver rejects `-z`
  outright, so pass the equivalent lld flag `-Wl,--allow-multiple-definition`.
- `strace-bundled-btrfs-include.patch` — `src/btrfs.c` must include strace's
  bundled UAPI headers (`bundled/linux/include/uapi/linux/btrfs.h` and
  `btrfs_tree.h`) by quoted relative path, because zig's own older
  `<linux/btrfs*.h>` otherwise shadow the bundled copies that define the btrfs
  xlat constants.

This directory still exists so that adding a patch is a zero-workflow-change
operation — the manifest field is the only thing a contributor touches.
