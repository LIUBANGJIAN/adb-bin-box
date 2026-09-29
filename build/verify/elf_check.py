#!/usr/bin/env python3
"""elf_check.py — structural ELF gate for adb-bin-box artifacts.

A binary is considered *truly static* when it carries **no** ``PT_INTERP``
program header, i.e. the kernel needs no dynamic loader to map it.  That is a
structural judgement (parsed straight out of the ELF program header table),
which is deliberately stronger than the textual "statically linked" that
``file(1)`` reports and works in minimal containers with **no binutils**
installed.  See system_design.md §4.3.

The check is a hard gate (design §8): when ``build.sh`` receives a non-zero
exit here it aborts the job with engine exit code ``2`` (verification failed).

Exit codes
----------
0  verification passed
1  verification failed (reasons are printed / emitted as JSON)
2  usage error (bad arguments / unreadable file)

The prototype this is derived from lived at
``$TEMP/zigspike/verify_elf.py``; the parsing logic is preserved verbatim and
wrapped in a parameterised CLI + machine/ABI aware assertion layer.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

# --------------------------------------------------------------------------- #
# ELF constants                                                               #
# --------------------------------------------------------------------------- #
ELF_MAGIC = b"\x7fELF"
ELFCLASS32 = 1
ELFCLASS64 = 2
ELFDATA2LSB = 1
ELFDATA2MSB = 2

ET_NONE = 0
ET_REL = 1
ET_EXEC = 2
ET_DYN = 3
ET_CORE = 4

PT_LOAD = 1
PT_INTERP = 3
PF_X = 1

EM_MACHINE_NAMES: Dict[int, str] = {
    0: "none",
    2: "SPARC",
    3: "i386",
    8: "MIPS",
    20: "PowerPC",
    21: "PowerPC64",
    40: "ARM",
    62: "x86_64",
    183: "AArch64",
    243: "RISC-V",
    258: "LoongArch",
}
EM_MACHINE_IDS: Dict[str, int] = {
    name.lower(): code for code, name in EM_MACHINE_NAMES.items()
}

DEFAULT_MIN_SIZE = 1024               # 1 KiB
DEFAULT_MAX_SIZE = 50 * 1024 * 1024   # 50 MiB

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ABI_MATRIX_PATH = os.path.join(REPO_ROOT, "build", "verify", "abi_matrix.json")


# --------------------------------------------------------------------------- #
# Result model (mirrors VerifyResult in system_design.md §3.1)                 #
# --------------------------------------------------------------------------- #
@dataclass
class VerifyResult:
    path: str
    is_static: bool = False
    has_pt_interp: bool = False
    e_machine: int = 0
    e_machine_name: str = "unknown"
    e_type: int = 0
    bits: int = 0
    endian: str = "?"
    size: int = 0
    interp: Optional[str] = None
    executable_load: bool = False
    ok: bool = False
    reasons: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "path": self.path,
            "ok": self.ok,
            "is_static": self.is_static,
            "has_pt_interp": self.has_pt_interp,
            "e_machine": self.e_machine,
            "e_machine_name": self.e_machine_name,
            "e_type": self.e_type,
            "bits": self.bits,
            "endian": self.endian,
            "size": self.size,
            "interp": self.interp,
            "executable_load": self.executable_load,
            "reasons": self.reasons,
        }


# --------------------------------------------------------------------------- #
# ELF parser                                                                   #
# --------------------------------------------------------------------------- #
class ElfParseError(Exception):
    """Raised when the file is not a parseable ELF."""


def parse_elf(path: str) -> Dict[str, Any]:
    """Parse minimal ELF structure needed for the static-ness judgement."""
    with open(path, "rb") as handle:
        data = handle.read()

    if len(data) < 64 or data[:4] != ELF_MAGIC:
        raise ElfParseError("%s: not an ELF file (bad magic)" % path)

    ei_class = data[4]
    ei_data = data[5]
    if ei_class not in (ELFCLASS32, ELFCLASS64):
        raise ElfParseError("%s: unknown ELF class %d" % (path, ei_class))
    if ei_data not in (ELFDATA2LSB, ELFDATA2MSB):
        raise ElfParseError("%s: unknown ELF data encoding %d" % (path, ei_data))

    is64 = ei_class == ELFCLASS64
    little = ei_data == ELFDATA2LSB
    endian = "<" if little else ">"
    endian_name = "LSB" if little else "MSB"

    e_type = struct.unpack_from(endian + "H", data, 16)[0]
    e_machine = struct.unpack_from(endian + "H", data, 18)[0]

    if is64:
        phoff = struct.unpack_from(endian + "Q", data, 32)[0]
        phentsize = struct.unpack_from(endian + "H", data, 54)[0]
        phnum = struct.unpack_from(endian + "H", data, 56)[0]
    else:
        phoff = struct.unpack_from(endian + "I", data, 28)[0]
        phentsize = struct.unpack_from(endian + "H", data, 42)[0]
        phnum = struct.unpack_from(endian + "H", data, 44)[0]

    if phoff == 0 or phnum == 0 or phentsize == 0:
        raise ElfParseError("%s: no program header table (not an executable)" % path)

    interp: Optional[str] = None
    executable_load = False

    for index in range(phnum):
        base = phoff + index * phentsize
        if base + phentsize > len(data):
            raise ElfParseError("%s: program header %d out of bounds" % (path, index))
        p_type = struct.unpack_from(endian + "I", data, base)[0]
        if is64:
            p_flags = struct.unpack_from(endian + "I", data, base + 4)[0]
            p_offset = struct.unpack_from(endian + "Q", data, base + 8)[0]
            p_filesz = struct.unpack_from(endian + "Q", data, base + 32)[0]
        else:
            p_offset = struct.unpack_from(endian + "I", data, base + 4)[0]
            p_filesz = struct.unpack_from(endian + "I", data, base + 16)[0]
            p_flags = struct.unpack_from(endian + "I", data, base + 24)[0]

        if p_type == PT_INTERP:
            raw = data[p_offset : p_offset + p_filesz]
            interp = raw.rstrip(b"\x00").decode("utf-8", "replace")
        elif p_type == PT_LOAD and (p_flags & PF_X):
            executable_load = True

    return {
        "is64": is64,
        "bits": 64 if is64 else 32,
        "endian": endian_name,
        "e_type": e_type,
        "e_machine": e_machine,
        "machine_name": EM_MACHINE_NAMES.get(e_machine, "unknown(%d)" % e_machine),
        "interp": interp,
        "static": interp is None,
        "executable_load": executable_load,
        "size": len(data),
    }


# --------------------------------------------------------------------------- #
# Verification                                                                 #
# --------------------------------------------------------------------------- #
def _load_expected_from_abi(abi: str, abi_matrix_path: str) -> Dict[str, Any]:
    with open(abi_matrix_path, "r", encoding="utf-8") as handle:
        matrix = json.load(handle)
    if abi not in matrix:
        raise ElfParseError(
            "unknown ABI %r (known: %s)" % (abi, ", ".join(sorted(matrix)))
        )
    entry = matrix[abi]
    return {"e_machine": int(entry["e_machine"]), "bits": int(entry["bits"])}


def verify(
    path: str,
    expected_machine: Optional[int] = None,
    expected_bits: Optional[int] = None,
    min_size: int = DEFAULT_MIN_SIZE,
    max_size: int = DEFAULT_MAX_SIZE,
) -> VerifyResult:
    """Verify a single binary, returning a fully-populated result."""
    result = VerifyResult(path=path)

    if not os.path.isfile(path):
        result.reasons.append("file not found")
        return result

    try:
        info = parse_elf(path)
    except ElfParseError as exc:
        result.reasons.append(str(exc))
        return result

    result.is_static = bool(info["static"])
    result.has_pt_interp = info["interp"] is not None
    result.e_machine = info["e_machine"]
    result.e_machine_name = info["machine_name"]
    result.e_type = info["e_type"]
    result.bits = info["bits"]
    result.endian = info["endian"]
    result.size = info["size"]
    result.interp = info["interp"]
    result.executable_load = info["executable_load"]

    # -- structural static-ness (the hard gate) ----------------------------- #
    if result.has_pt_interp:
        result.reasons.append(
            "has PT_INTERP (%r) -> dynamically linked" % result.interp
        )

    if not result.executable_load:
        result.reasons.append("no executable PT_LOAD segment")

    if result.e_type not in (ET_EXEC, ET_DYN):
        result.reasons.append(
            "e_type 0x%x is not ET_EXEC/ET_DYN (not an executable)" % result.e_type
        )

    # -- architecture ------------------------------------------------------- #
    if expected_machine is not None and result.e_machine != expected_machine:
        result.reasons.append(
            "e_machine mismatch: expected %d (%s) got %d (%s)"
            % (
                expected_machine,
                EM_MACHINE_NAMES.get(expected_machine, "?"),
                result.e_machine,
                result.e_machine_name,
            )
        )

    if expected_bits is not None and result.bits != expected_bits:
        result.reasons.append(
            "bit-width mismatch: expected %d got %d" % (expected_bits, result.bits)
        )

    # -- sanity: size window ------------------------------------------------ #
    if result.size < min_size:
        result.reasons.append(
            "size %d bytes < minimum %d" % (result.size, min_size)
        )
    if result.size > max_size:
        result.reasons.append(
            "size %d bytes > maximum %d" % (result.size, max_size)
        )

    result.ok = not result.reasons
    return result


# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #
def _resolve_machine(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    text = value.strip()
    if text.lstrip("-").isdigit():
        return int(text)
    key = text.lower()
    if key in EM_MACHINE_IDS:
        return EM_MACHINE_IDS[key]
    raise ElfParseError("unknown machine %r" % value)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="elf_check.py",
        description="Structurally verify that an ELF is a static binary of the "
        "expected machine.",
    )
    parser.add_argument("binary", help="path to the ELF binary to verify")
    parser.add_argument("expected_machine_pos", nargs="?", default=None,
                        help="deprecated positional machine (int or name)")
    parser.add_argument("--machine", default=None,
                        help="expected e_machine as int or name (e.g. 183 / AArch64)")
    parser.add_argument("--abi", default=None,
                        help="Android ABI; pulls e_machine+bits from abi_matrix.json")
    parser.add_argument("--abi-matrix", default=ABI_MATRIX_PATH,
                        help="path to abi_matrix.json (default: %s)" % ABI_MATRIX_PATH)
    parser.add_argument("--bits", type=int, default=None, choices=(32, 64),
                        help="expected bit width")
    parser.add_argument("--min-size", type=int, default=DEFAULT_MIN_SIZE)
    parser.add_argument("--max-size", type=int, default=DEFAULT_MAX_SIZE)
    parser.add_argument("--json", action="store_true", help="emit a JSON verdict")
    parser.add_argument("--quiet", action="store_true", help="only set the exit code")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    expected_machine = _resolve_machine(args.machine)
    expected_bits = args.bits

    try:
        if args.abi:
            abi_expected = _load_expected_from_abi(args.abi, args.abi_matrix)
            if expected_machine is None:
                expected_machine = abi_expected["e_machine"]
            if expected_bits is None:
                expected_bits = abi_expected["bits"]
        if expected_machine is None and args.expected_machine_pos:
            expected_machine = _resolve_machine(args.expected_machine_pos)
    except (ElfParseError, OSError, ValueError, KeyError) as exc:
        sys.stderr.write("USAGE: %s\n" % exc)
        return 2

    result = verify(
        args.binary,
        expected_machine=expected_machine,
        expected_bits=expected_bits,
        min_size=args.min_size,
        max_size=args.max_size,
    )

    if args.json:
        sys.stdout.write(json.dumps(result.to_dict(), indent=2) + "\n")
    elif not args.quiet:
        verdict = "PASS" if result.ok else "FAIL"
        sys.stdout.write(
            "%s %s class=ELF%d endian=%s machine=%s(%d) type=0x%x interp=%r size=%d\n"
            % (
                verdict,
                os.path.basename(result.path),
                result.bits,
                result.endian,
                result.e_machine_name,
                result.e_machine,
                result.e_type,
                result.interp,
                result.size,
            )
        )
        for reason in result.reasons:
            sys.stdout.write("  - %s\n" % reason)

    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
