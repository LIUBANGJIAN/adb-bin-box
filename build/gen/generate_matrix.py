#!/usr/bin/env python3
"""generate_matrix.py — manifest → ``strategy.matrix`` JSON.

Implements the "清单 → 动态矩阵" artery (system_design.md §4.1): the enabled
tools × their ABIs are expanded into a flat ``{"include": [...]}`` array that a
GitHub Actions job consumes verbatim via
``strategy.matrix: ${{ fromJSON(needs.generate.outputs.matrix) }}``.

Selection (added for on-demand builds):
  --only    <id1,id2>   build *only* these tools (empty = all)
  --exclude <id1,id2>   drop these tools
Unknown ids in --only/--exclude abort with exit 1 (typos must never silently
produce an empty matrix), and a selection that matches nothing also aborts.

Fully default-expanded and dependency-resolved specs are produced by
``manifest.py`` — this file never parses YAML itself.

Exit codes: 0 = ok, 1 = manifest invalid / unknown tool id / empty selection.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from manifest import (  # noqa: E402  (path shim must run first)
    DEFAULT_ABIS,
    AbiMatrix,
    Manifest,
    ManifestError,
    load_manifest,
)

# GitHub rejects matrices with more than this many jobs; we shard accordingly.
DEFAULT_MAX_PER_SHARD = 256


@dataclass
class MatrixEntry:
    """One (tool, abi) build unit — a single reusable-workflow invocation."""

    tool_id: str
    abi: str
    zig_target: str
    e_machine: int
    runner: str
    dep_ids: List[str]
    job_name: str
    tool_version: str
    tool_bin: str
    build_system: str

    def to_dict(self) -> Dict[str, Any]:
        return {
            "tool_id": self.tool_id,
            "abi": self.abi,
            "zig_target": self.zig_target,
            "e_machine": self.e_machine,
            "runner": self.runner,
            "dep_ids": self.dep_ids,
            "job_name": self.job_name,
            "tool_version": self.tool_version,
            "tool_bin": self.tool_bin,
            "build_system": self.build_system,
        }


@dataclass
class BuildMatrix:
    include: List[Dict[str, Any]] = field(default_factory=list)

    @property
    def size(self) -> int:
        return len(self.include)

    def to_json(self, compact: bool = True) -> str:
        payload = {"include": self.include}
        if compact:
            return json.dumps(payload, separators=(",", ":"))
        return json.dumps(payload, indent=2)


class MatrixGenerator:
    """Builds a ``BuildMatrix`` from a validated ``Manifest``."""

    def __init__(self, manifest: Manifest, matrix: Optional[AbiMatrix] = None) -> None:
        self.manifest = manifest
        self.matrix = matrix or manifest.matrix or AbiMatrix.load()

    def known_tool_ids(self) -> List[str]:
        return sorted(t["id"] for t in self.manifest.tools)

    def build(
        self,
        abis: Optional[List[str]] = None,
        shard: Optional[int] = None,
        max_per_shard: int = DEFAULT_MAX_PER_SHARD,
        only: Optional[List[str]] = None,
        exclude: Optional[List[str]] = None,
    ) -> BuildMatrix:
        """Cartesian product of selected tools × their ABIs.

        ``abis`` restricts the ABI set, ``only``/``exclude`` restrict the tool
        set.  Unknown ids raise ``ManifestError``.  ``shard`` selects a slice of
        at most ``max_per_shard`` entries, enabling >256-job builds.
        """
        known = set(self.known_tool_ids())
        only_set = set(only) if only else None
        exclude_set = set(exclude) if exclude else set()

        if only_set:
            unknown = sorted(only_set - known)
            if unknown:
                raise ManifestError(
                    "unknown tool id(s) in --only: %s; available: %s"
                    % (", ".join(unknown), ", ".join(sorted(known)))
                )
        unknown_ex = sorted(exclude_set - known)
        if unknown_ex:
            raise ManifestError(
                "unknown tool id(s) in --exclude: %s; available: %s"
                % (", ".join(unknown_ex), ", ".join(sorted(known)))
            )

        requested = list(abis) if abis else None
        entries: List[Dict[str, Any]] = []

        for tool in self.manifest.enabled_tools():
            tool_id = tool["id"]
            if only_set is not None and tool_id not in only_set:
                continue
            if tool_id in exclude_set:
                continue
            tool_abis = [a for a in tool["abis"] if requested is None or a in requested]
            for abi in tool_abis:
                abi_spec = self.matrix.get(abi)
                deps = self.manifest.resolve_deps(tool_id, abi)
                entry = MatrixEntry(
                    tool_id=tool_id,
                    abi=abi,
                    zig_target=abi_spec.zig_target,
                    e_machine=abi_spec.e_machine,
                    runner=abi_spec.runner,
                    dep_ids=[d["id"] for d in deps],
                    job_name="%s-%s" % (tool_id, abi),
                    tool_version=tool["version"],
                    tool_bin=tool["bin"],
                    build_system=tool["build_system"],
                )
                entries.append(entry.to_dict())

        if shard is not None:
            if max_per_shard <= 0:
                raise ManifestError("max_per_shard must be > 0")
            start = shard * max_per_shard
            end = start + max_per_shard
            entries = entries[start:end]

        return BuildMatrix(include=entries)

    def shard_count(self, max_per_shard: int = DEFAULT_MAX_PER_SHARD) -> int:
        total = self.build().size
        if total == 0:
            return 0
        return (total + max_per_shard - 1) // max_per_shard


def _parse_list(value: Optional[str]) -> Optional[List[str]]:
    """Parse a comma-separated CLI list; empty/None -> None."""
    if value is None:
        return None
    items = [part.strip() for part in value.split(",") if part.strip()]
    return items or None


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="generate_matrix.py",
        description="Expand tools.yml into a GitHub Actions strategy.matrix JSON.",
    )
    parser.add_argument("manifest", nargs="?", default="tools.yml",
                        help="path to tools.yml (default: tools.yml)")
    parser.add_argument("--tools", default=None,
                        help="alias for the positional manifest PATH (not a tool list)")
    parser.add_argument("--deps", default="deps.yml", help="path to deps.yml")
    parser.add_argument("--abis", default=None,
                        help="comma-separated ABI subset (default: all)")
    parser.add_argument("--only", default=None,
                        help="comma-separated tool ids to build (default: all)")
    parser.add_argument("--exclude", default=None,
                        help="comma-separated tool ids to skip")
    parser.add_argument("--shard", type=int, default=None,
                        help="zero-based shard index (default: all entries)")
    parser.add_argument("--max-per-shard", type=int, default=DEFAULT_MAX_PER_SHARD,
                        help="max entries per shard (default: %d)" % DEFAULT_MAX_PER_SHARD)
    parser.add_argument("--pretty", action="store_true", help="indent the JSON output")
    parser.add_argument("--out", default=None, help="write JSON here (default: stdout)")
    parser.add_argument("--count-only", action="store_true",
                        help="print only the number of entries")
    parser.add_argument("--to-github-output", default=None,
                        help="append 'matrix=<json>' to this file (GITHUB_OUTPUT)")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    tools_path = args.tools or args.manifest
    deps_path = args.deps if args.deps and os.path.exists(args.deps) else None

    try:
        manifest = load_manifest(tools_path, deps_path)
        generator = MatrixGenerator(manifest)
        build_matrix = generator.build(
            abis=_parse_list(args.abis),
            shard=args.shard,
            max_per_shard=args.max_per_shard,
            only=_parse_list(args.only),
            exclude=_parse_list(args.exclude),
        )
    except ManifestError as exc:
        sys.stderr.write("MATRIX ERROR: %s\n" % exc)
        return 1

    # An empty matrix makes the GitHub Actions build job fail with an opaque
    # error; fail early with a clear message instead (only when not sharding,
    # since a later shard legitimately can be empty).
    if build_matrix.size == 0 and args.shard is None:
        sys.stderr.write(
            "MATRIX ERROR: no tools matched "
            "(only=%r exclude=%r abis=%r; available: %s)\n"
            % (args.only, args.exclude, args.abis, ", ".join(generator.known_tool_ids()))
        )
        return 1

    if args.count_only:
        sys.stdout.write("%d\n" % build_matrix.size)
        return 0

    text = build_matrix.to_json(compact=not args.pretty)

    if args.to_github_output:
        with open(args.to_github_output, "a", encoding="utf-8") as handle:
            handle.write("matrix=%s\n" % text)
        with open(args.to_github_output, "a", encoding="utf-8") as handle:
            handle.write("count=%d\n" % build_matrix.size)
        sys.stderr.write("wrote matrix (%d entries) to %s\n"
                         % (build_matrix.size, args.to_github_output))
        return 0

    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
        sys.stderr.write("wrote %d entries to %s\n" % (build_matrix.size, args.out))
    else:
        sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
