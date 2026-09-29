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

No patches are required for the Phase 1 recipes in `tools.yml`. This directory
exists so that adding a patch is a zero-workflow-change operation — the manifest
field is the only thing a contributor touches.

If `strace` fails on musl (the known-risk item, design §1.4 / U6), the expected
fix lands here as `strace-musl-*.patch` rather than as a change to the engine.
