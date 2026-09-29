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

Four patches are currently in use (each `tools.yml` entry lists its own, in
apply order):

- `stress-ng-arch-typo.patch` — upstream's `core-helper.c` calls
  `stress_get_arch()`, but the real function is `stress_arch_get()`; the broken
  call sites only compile in our cross build, so fix the word order.
- `stress-ng-drop-muldefs.patch` — the Makefile's `STATIC=1` LDFLAGS hardcodes
  the GNU-ld-only `-z muldefs` behind an `override`; zig's cc driver rejects
  `-z` outright, and it equally rejects the lld replacement
  `--allow-multiple-definition`, so no form of the flag reaches the linker
  through `zig cc`.  The patch removes it and adds `-fcommon` (the compile-time
  equivalent for tentative definitions) as a safety net.
- `stress-ng-memthrash-macro-parens.patch` — `stress-memthrash.c`'s fallback
  macros omit the parentheses around `addr` (`(*addr)` and
  `(*addr) = (val)`), but every call site passes an expression (`ptr + 6`).
  Since macro expansion is textual, `MEMTHRASH_STORE128(ptr + 6, r6)` expands to
  `*ptr + 6 = r6` → `expression is not assignable`.  Only `x86_64` reaches that
  fallback (it is the only target with `HAVE_INT128_T` +
  `HAVE_ASM_X86_MOVNTDQA` but no `HAVE_NT_STORE128`).  The `MEMTHRASH_LOAD128`
  fallback has the same defect and read from the wrong address.  Both lines get
  the missing parentheses; the call sites are left alone.
- `strace-bundled-btrfs-include.patch` — `src/btrfs.c` must include strace's
  bundled UAPI headers (`bundled/linux/include/uapi/linux/btrfs.h` and
  `btrfs_tree.h`) by quoted relative path, because zig's own older
  `<linux/btrfs*.h>` otherwise shadow the bundled copies that define the btrfs
  xlat constants.

This directory still exists so that adding a patch is a zero-workflow-change
operation — the manifest field is the only thing a contributor touches.
