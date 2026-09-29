# build/verify — quality gates

Two independent, **hard** gates run for every built binary
(system_design.md §3.1 VerifyResult / SmokeResult, §4.3):

## 1. `elf_check.py` — structural ELF gate (exit 2 on failure)

A binary is accepted only if its **structure** says it is static:

| Check | Rationale |
|---|---|
| magic `\x7fELF`, ELFCLASS, ELFDATA parse | file is a real ELF |
| **no `PT_INTERP` program header** | *the* static-ness criterion — no dynamic loader is needed |
| at least one executable `PT_LOAD` | it is actually runnable |
| `e_type` ∈ {ET_EXEC, ET_DYN} | executable, not relocatable/core |
| `e_machine` == expected (from `abi_matrix.json`) | built for the right architecture |
| bit width matches the ABI | 32 vs 64 sanity |
| size ∈ [1 KiB, 50 MiB] | catches truncated / absurd artifacts |

`is_static = NOT has_pt_interp` is deliberately **structural**: it rejects a
binary that merely *looks* static in `file(1)` output. Everything is parsed with
the Python standard library, so the gate works in containers without binutils.

```sh
python build/verify/elf_check.py --abi arm64-v8a dist/curl/arm64-v8a/curl
python build/verify/elf_check.py --machine 183 --json dist/curl/arm64-v8a/curl
```

Exit codes: `0` pass · `1` verification failed · `2` usage error.
The engine maps any non-zero result to build-engine exit code **2**.

## 2. `smoke_test.sh` — real execution (exit 3 on failure)

Proves the artifact actually *runs*:

* `x86_64` / `x86` run **natively** on the x86_64 runner;
* `arm64-v8a` / `armeabi-v7a` run through `qemu-*-static`, or directly when
  binfmt_misc is registered (`docker/setup-qemu-action` does this in CI).

It asserts the exit code (`smoke.expect_exit`) and, when set, a substring of the
output (`smoke.contains`), e.g. `curl --version` must contain `curl 8.22.0`.

```sh
bash build/verify/smoke_test.sh --bin dist/htop/arm64-v8a/htop --abi arm64-v8a \
  --arg --version --expect-exit 0 --contains 3.5.3
```

Exit codes: `0` pass · `3` smoke failure · `2` usage error.

## ABI truth source

`abi_matrix.json` is the **only** place zig targets ↔ `e_machine` ↔ qemu are
mapped. `elf_check.py`, `smoke_test.sh` and the matrix generator all read it;
no script hardcodes a triple (system_design.md §8).
