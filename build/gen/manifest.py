#!/usr/bin/env python3
"""adb-bin-box manifest loader / validator / default-expander / dep-resolver.

This module is the single source of truth for *reading* the declarative
manifests (``tools.yml`` / ``deps.yml``).  It is intentionally dependency-light:
PyYAML is the only third-party import, everything else is stdlib.  It is used
both as a library (imported by ``generate_matrix.py``) and as a CLI (invoked by
the shell build engine through the ``shell`` / ``dep-shell`` sub-commands).

Design references: system_design.md §3.2 (tools.yml schema), §3.3 (deps.yml
schema), §3.5 (abi matrix), §8 (shared conventions).

Exit codes (CLI): 0 = ok, 1 = manifest invalid / unreadable.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

try:
    import yaml
except ImportError as exc:  # pragma: no cover - environment guard
    sys.stderr.write(
        "FATAL: PyYAML is required (pip install pyyaml).  Original error: %s\n" % exc
    )
    raise SystemExit(1)


# --------------------------------------------------------------------------- #
# Constants (mirror system_design.md §3.2 / §3.3 / §8)                         #
# --------------------------------------------------------------------------- #
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ABI_MATRIX_PATH = os.path.join(REPO_ROOT, "build", "verify", "abi_matrix.json")

SCHEMA_VERSION = 1

DEFAULT_ABIS = ["arm64-v8a", "armeabi-v7a", "x86_64", "x86"]
DEFAULT_CFLAGS = "-O2 -fPIC"
DEFAULT_LDFLAGS = "-static"
DEFAULT_SOURCE_TYPE = "tarball"
DEFAULT_STRIP_COMPONENTS = 1
DEFAULT_SMOKE_ARGS = ["--version"]
DEFAULT_SMOKE_EXPECT_EXIT = 0
DEFAULT_MAKE_TARGETS = ["all"]
DEFAULT_MAKE_INSTALL_TARGET = "install"

BUILD_SYSTEMS = {"autotools", "cmake", "make", "meson", "go", "script"}
SOURCE_TYPES = {"tarball", "git", "local"}
HOOK_KEYS = [
    "pre_configure",
    "post_configure",
    "pre_build",
    "post_build",
    "post_install",
]

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


class ManifestError(Exception):
    """Raised when a manifest is structurally invalid."""


# --------------------------------------------------------------------------- #
# Small helpers                                                               #
# --------------------------------------------------------------------------- #
def as_list(value: Any) -> List[Any]:
    """Coerce ``None``/scalar/list into a (possibly empty) list."""
    if value is None:
        return []
    if isinstance(value, list):
        return list(value)
    return [value]


def as_str_list(value: Any) -> List[str]:
    """Coerce into a list of strings (used for flags / commands / args)."""
    return [str(item) for item in as_list(value)]


def deep_merge(base: Dict[str, Any], override: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively merge ``override`` into ``base``.

    Maps are merged key-by-key; every other type (including lists) is replaced
    wholesale.  This matches the "深合并" semantics required by
    ``abi_overrides`` in system_design.md §3.2.
    """
    result: Dict[str, Any] = dict(base)
    for key, value in override.items():
        if (
            key in result
            and isinstance(result[key], dict)
            and isinstance(value, dict)
        ):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def expand_template(text: str, version: str, tag: Optional[str]) -> str:
    """Expand ``{version}`` / ``{tag}`` placeholders in a source URL."""
    if text is None:
        return text
    out = text.replace("{version}", version)
    if tag is not None:
        out = out.replace("{tag}", tag)
    return out


def expand_tokens(text: str, mapping: Dict[str, str]) -> str:
    """Expand ``${VAR}`` / ``$VAR`` runtime tokens (e.g. ``$PREFIX``)."""
    if text is None:
        return text
    out = str(text)
    for key, value in mapping.items():
        out = out.replace("${%s}" % key, value).replace("$%s" % key, value)
    return out


def _load_yaml(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    if data is None:
        raise ManifestError("%s is empty" % path)
    if not isinstance(data, dict):
        raise ManifestError("%s: top level must be a mapping" % path)
    return data


# --------------------------------------------------------------------------- #
# ABI matrix (single source of truth, system_design.md §3.5)                   #
# --------------------------------------------------------------------------- #
@dataclass
class AbiSpec:
    abi: str
    zig_target: str
    e_machine: int
    machine_name: str
    bits: int
    qemu: Optional[str]
    runner: str
    # ``autotools_host`` is the GNU triple passed to ``./configure --host=``.
    # It is *not* always identical to ``zig_target``: some upstream configure
    # scripts whitelist CPU names (e.g. strace only accepts ``i[[3456]]86``, so
    # ``x86-linux-musl`` -> host_cpu ``x86`` is rejected while ``i686-linux-musl``
    # works).  ``karch`` is the Linux kernel arch name strace uses to locate its
    # bundled ``arch/<karch>/include/uapi`` tree (``arm64``/``arm``/``x86``).
    autotools_host: Optional[str] = None
    karch: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "abi": self.abi,
            "zig_target": self.zig_target,
            "e_machine": self.e_machine,
            "machine_name": self.machine_name,
            "bits": self.bits,
            "qemu": self.qemu,
            "runner": self.runner,
            "autotools_host": self.autotools_host or self.zig_target,
            "karch": self.karch,
        }


class AbiMatrix:
    """Loads ``build/verify/abi_matrix.json`` — never hardcode a zig triple."""

    def __init__(self, specs: Dict[str, AbiSpec]) -> None:
        self._specs = specs

    @classmethod
    def load(cls, path: str = ABI_MATRIX_PATH) -> "AbiMatrix":
        try:
            with open(path, "r", encoding="utf-8") as handle:
                raw = json.load(handle)
        except OSError as exc:
            raise ManifestError("cannot read ABI matrix %s: %s" % (path, exc))
        specs: Dict[str, AbiSpec] = {}
        for abi, entry in raw.items():
            if not isinstance(entry, dict):
                raise ManifestError("abi_matrix[%s] must be a mapping" % abi)
            for required in ("zig_target", "e_machine", "bits"):
                if required not in entry:
                    raise ManifestError("abi_matrix[%s] missing %s" % (abi, required))
            specs[abi] = AbiSpec(
                abi=abi,
                zig_target=str(entry["zig_target"]),
                e_machine=int(entry["e_machine"]),
                machine_name=str(entry.get("machine_name", "")),
                bits=int(entry["bits"]),
                qemu=entry.get("qemu"),
                runner=str(entry.get("runner", "ubuntu-24.04")),
                autotools_host=(
                    str(entry["autotools_host"]) if entry.get("autotools_host") else None
                ),
                karch=str(entry.get("karch", "")),
            )
        if not specs:
            raise ManifestError("ABI matrix %s is empty" % path)
        return cls(specs)

    @property
    def abis(self) -> List[str]:
        return list(self._specs.keys())

    def get(self, abi: str) -> AbiSpec:
        if abi not in self._specs:
            raise ManifestError(
                "unknown ABI %r (known: %s)" % (abi, ", ".join(self._specs))
            )
        return self._specs[abi]

    def has(self, abi: str) -> bool:
        return abi in self._specs


# --------------------------------------------------------------------------- #
# Normalised spec builders                                                    #
# --------------------------------------------------------------------------- #
def normalize_source(raw: Optional[Dict[str, Any]], version: str) -> Dict[str, Any]:
    src = dict(raw or {})
    stype = str(src.get("type", DEFAULT_SOURCE_TYPE))
    if stype not in SOURCE_TYPES:
        raise ManifestError("source.type %r not in %s" % (stype, sorted(SOURCE_TYPES)))
    tag = src.get("tag")
    if tag is not None:
        tag = expand_template(str(tag), version, tag)
    url = src.get("url")
    if url is not None:
        url = expand_template(str(url), version, tag)
    return {
        "type": stype,
        "url": url,
        "tag": tag,
        "strip_components": int(src.get("strip_components", DEFAULT_STRIP_COMPONENTS)),
    }


def normalize_configure(raw: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    cfg = dict(raw or {})
    return {
        "flags": as_str_list(cfg.get("flags")),
        "command": cfg.get("command"),
        "bootstrap": as_str_list(cfg.get("bootstrap")),
    }


def normalize_make(raw: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    mk = dict(raw or {})
    return {
        "targets": as_str_list(mk.get("targets")) or list(DEFAULT_MAKE_TARGETS),
        "install_target": str(mk.get("install_target", DEFAULT_MAKE_INSTALL_TARGET)),
        "install_vars": as_str_list(mk.get("install_vars")),
        "args": as_str_list(mk.get("args")),
    }


def normalize_hooks(raw: Optional[Dict[str, Any]]) -> Dict[str, List[str]]:
    hk = dict(raw or {})
    hooks: Dict[str, List[str]] = {}
    for key in HOOK_KEYS:
        hooks[key] = as_str_list(hk.get(key))
    unknown = set(hk) - set(HOOK_KEYS)
    if unknown:
        raise ManifestError("unknown hook keys: %s" % sorted(unknown))
    return hooks


def normalize_artifacts(raw: Any) -> List[Dict[str, Any]]:
    rules: List[Dict[str, Any]] = []
    for entry in as_list(raw):
        if not isinstance(entry, dict):
            raise ManifestError("artifact rule must be a mapping, got %r" % entry)
        if "path" not in entry:
            raise ManifestError("artifact rule missing 'path': %r" % entry)
        rules.append(
            {
                "path": str(entry["path"]),
                "bin_name": entry.get("bin_name"),
                "strip": bool(entry.get("strip", False)),
                "required": bool(entry.get("required", True)),
            }
        )
    return rules


def normalize_smoke(raw: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    sm = dict(raw or {})
    args = as_str_list(sm.get("args"))
    return {
        "args": args if args else list(DEFAULT_SMOKE_ARGS),
        "expect_exit": int(sm.get("expect_exit", DEFAULT_SMOKE_EXPECT_EXIT)),
        "contains": sm.get("contains"),
    }


def normalize_tool(
    raw: Dict[str, Any], defaults: Dict[str, Any], matrix: AbiMatrix
) -> Dict[str, Any]:
    """Turn a raw ToolSpec mapping into a fully-populated, validated dict."""
    if not isinstance(raw, dict):
        raise ManifestError("tool entry must be a mapping, got %r" % raw)
    tool_id = raw.get("id")
    if not tool_id:
        raise ManifestError("tool entry missing 'id'")
    if not SLUG_RE.match(str(tool_id)):
        raise ManifestError(
            "tool id %r must be lowercase [a-z0-9._-]" % tool_id
        )
    if "version" not in raw:
        raise ManifestError("tool %r missing 'version'" % tool_id)

    version = str(raw["version"])
    build_system = str(raw.get("build_system", "autotools"))
    if build_system not in BUILD_SYSTEMS:
        raise ManifestError(
            "tool %r: build_system %r not in %s"
            % (tool_id, build_system, sorted(BUILD_SYSTEMS))
        )

    abis = as_str_list(raw.get("abis")) or list(defaults.get("abis") or DEFAULT_ABIS)
    for abi in abis:
        if not matrix.has(abi):
            raise ManifestError(
                "tool %r references unknown ABI %r" % (tool_id, abi)
            )

    env_raw = raw.get("env") or {}
    if not isinstance(env_raw, dict):
        raise ManifestError("tool %r: env must be a mapping" % tool_id)

    normalized = {
        "id": str(tool_id),
        "name": str(raw.get("name", tool_id)),
        "version": version,
        "repo": str(raw.get("repo", "")),
        "build_system": build_system,
        "source": normalize_source(raw.get("source"), version),
        "deps": as_str_list(raw.get("deps")),
        "features": as_str_list(raw.get("features")),
        "abis": abis,
        "bin": str(raw.get("bin", tool_id)),
        "tier": int(raw.get("tier", 0)),
        "enabled": bool(raw.get("enabled", True)),
        "env": {str(k): str(v) for k, v in env_raw.items()},
        "configure": normalize_configure(raw.get("configure")),
        "make": normalize_make(raw.get("make")),
        "hooks": normalize_hooks(raw.get("hooks")),
        "patches": as_str_list(raw.get("patches")),
        "uapi_include": as_str_list(raw.get("uapi_include")),
        "artifacts": normalize_artifacts(raw.get("artifacts")),
        "smoke": normalize_smoke(raw.get("smoke")),
        "abi_overrides": raw.get("abi_overrides") or {},
        "notes": str(raw.get("notes", "")),
    }

    if "url" not in raw.get("source", {}) and normalized["source"]["type"] in (
        "tarball",
    ):
        raise ManifestError("tool %r: source.url is required" % tool_id)
    if normalized["source"]["type"] == "git" and not normalized["source"]["tag"]:
        raise ManifestError("tool %r: source.tag is required for git sources" % tool_id)
    return normalized


def normalize_dep(
    raw: Dict[str, Any], defaults: Dict[str, Any], matrix: AbiMatrix
) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        raise ManifestError("dep entry must be a mapping, got %r" % raw)
    dep_id = raw.get("id")
    if not dep_id:
        raise ManifestError("dep entry missing 'id'")
    if "version" not in raw:
        raise ManifestError("dep %r missing 'version'" % dep_id)
    build_system = str(raw.get("build_system", "autotools"))
    if build_system not in BUILD_SYSTEMS:
        raise ManifestError(
            "dep %r: build_system %r not in %s"
            % (dep_id, build_system, sorted(BUILD_SYSTEMS))
        )
    return {
        "id": str(dep_id),
        "version": str(raw["version"]),
        "repo": str(raw.get("repo", "")),
        "source": normalize_source(raw.get("source"), str(raw["version"])),
        "build_system": build_system,
        "configure": normalize_configure(raw.get("configure")),
        "make": normalize_make(raw.get("make")),
        "static": bool(raw.get("static", True)),
        "provides": as_str_list(raw.get("provides")),
        "env": {str(k): str(v) for k, v in (raw.get("env") or {}).items()},
        "abis": as_str_list(raw.get("abis")) or list(defaults.get("abis") or DEFAULT_ABIS),
        "abi_overrides": raw.get("abi_overrides") or {},
        "notes": str(raw.get("notes", "")),
    }


# --------------------------------------------------------------------------- #
# Manifest                                                                    #
# --------------------------------------------------------------------------- #
@dataclass
class Manifest:
    """Validated, default-expanded view over tools.yml + deps.yml."""

    version: int
    defaults: Dict[str, Any]
    tools: List[Dict[str, Any]] = field(default_factory=list)
    deps: List[Dict[str, Any]] = field(default_factory=list)
    matrix: Optional[AbiMatrix] = None

    # -- loading ----------------------------------------------------------- #
    @classmethod
    def load(
        cls,
        tools_path: str,
        deps_path: Optional[str] = None,
        matrix: Optional[AbiMatrix] = None,
    ) -> "Manifest":
        matrix = matrix or AbiMatrix.load()
        tools_raw = _load_yaml(tools_path)
        deps_raw = _load_yaml(deps_path) if deps_path else {}

        version = int(tools_raw.get("version", SCHEMA_VERSION))
        defaults = dict(tools_raw.get("defaults") or {})
        defaults.setdefault("abis", list(DEFAULT_ABIS))
        defaults.setdefault("cflags", DEFAULT_CFLAGS)
        defaults.setdefault("ldflags", DEFAULT_LDFLAGS)
        defaults.setdefault("strip", False)

        tools = [
            normalize_tool(entry, defaults, matrix)
            for entry in as_list(tools_raw.get("tools"))
        ]
        deps = [
            normalize_dep(entry, defaults, matrix)
            for entry in as_list(deps_raw.get("deps"))
        ]

        manifest = cls(
            version=version, defaults=defaults, tools=tools, deps=deps, matrix=matrix
        )
        manifest.validate()
        return manifest

    # -- validation -------------------------------------------------------- #
    def validate(self) -> None:
        if self.version != SCHEMA_VERSION:
            raise ManifestError(
                "unsupported manifest version %r (expected %d)"
                % (self.version, SCHEMA_VERSION)
            )
        seen_tools: Dict[str, int] = {}
        for tool in self.tools:
            if tool["id"] in seen_tools:
                raise ManifestError("duplicate tool id %r" % tool["id"])
            seen_tools[tool["id"]] = 1
            if not tool["bin"]:
                raise ManifestError("tool %r: empty bin name" % tool["id"])
            if tool["source"]["type"] == "tarball" and not tool["source"]["url"]:
                raise ManifestError("tool %r: missing source.url" % tool["id"])

        dep_ids = set()
        for dep in self.deps:
            if dep["id"] in dep_ids:
                raise ManifestError("duplicate dep id %r" % dep["id"])
            dep_ids.add(dep["id"])

        for tool in self.tools:
            for dep_id in tool["deps"]:
                if dep_id not in dep_ids:
                    raise ManifestError(
                        "tool %r references unknown dep %r" % (tool["id"], dep_id)
                    )

    # -- accessors --------------------------------------------------------- #
    def tool(self, tool_id: str) -> Dict[str, Any]:
        for entry in self.tools:
            if entry["id"] == tool_id:
                return entry
        raise ManifestError("unknown tool %r" % tool_id)

    def dep(self, dep_id: str) -> Dict[str, Any]:
        for entry in self.deps:
            if entry["id"] == dep_id:
                return entry
        raise ManifestError("unknown dep %r" % dep_id)

    def enabled_tools(self) -> List[Dict[str, Any]]:
        return [t for t in self.tools if t["enabled"]]

    def spec_for(self, tool_id: str, abi: str) -> Dict[str, Any]:
        """Return the tool spec with ``abi_overrides[abi]`` deep-merged in."""
        # ``self.tools`` is already normalised; merge overrides on the *raw* form
        # (kept by ``load_manifest``) and re-normalise, so that deep-merge
        # semantics of abi_overrides are honoured (system_design.md §3.2).
        raw = self._raw_tool(tool_id)
        override = (raw.get("abi_overrides") or {}).get(abi, {})
        merged = deep_merge(raw, override)
        return normalize_tool(merged, self.defaults, self.matrix)  # type: ignore[arg-type]

    def resolve_deps(self, tool_id: str, abi: Optional[str] = None) -> List[Dict[str, Any]]:
        """Resolve a tool's declared deps into normalised DepSpec dicts."""
        tool = self.tool(tool_id)
        resolved: List[Dict[str, Any]] = []
        for dep_id in tool["deps"]:
            raw = self._raw_dep(dep_id)
            if abi is not None:
                override = (raw.get("abi_overrides") or {}).get(abi, {})
                raw = deep_merge(raw, override)
            resolved.append(normalize_dep(raw, self.defaults, self.matrix))  # type: ignore[arg-type]
        return resolved

    # -- raw views (needed to honour abi_overrides deep-merge) ------------- #
    def _raw_tool(self, tool_id: str) -> Dict[str, Any]:
        return self._raw_tools[tool_id]

    def _raw_dep(self, dep_id: str) -> Dict[str, Any]:
        return self._raw_deps[dep_id]

    # populated by ``load_with_raw``; see below
    _raw_tools: Dict[str, Any] = field(default_factory=dict, repr=False)
    _raw_deps: Dict[str, Any] = field(default_factory=dict, repr=False)


def _attach_raw(manifest: Manifest, tools_path: str, deps_path: Optional[str]) -> None:
    """Re-read the raw manifests so abi_overrides can be deep-merged later."""
    tools_raw = _load_yaml(tools_path)
    manifest._raw_tools = {
        str(e.get("id")): e for e in as_list(tools_raw.get("tools")) if isinstance(e, dict)
    }
    if deps_path:
        deps_raw = _load_yaml(deps_path)
        manifest._raw_deps = {
            str(e.get("id")): e
            for e in as_list(deps_raw.get("deps"))
            if isinstance(e, dict)
        }


def load_manifest(
    tools_path: str, deps_path: Optional[str] = None
) -> Manifest:
    """Load + validate + keep raw view for abi_overrides resolution."""
    manifest = Manifest.load(tools_path, deps_path)
    _attach_raw(manifest, tools_path, deps_path)
    return manifest


# --------------------------------------------------------------------------- #
# Shell emission (build engine contract)                                       #
# --------------------------------------------------------------------------- #
def _sh_quote(value: Any) -> str:
    return "'" + str(value).replace("'", "'\\''") + "'"


def _sh_scalar(name: str, value: Any) -> str:
    return "%s=%s" % (name, _sh_quote(value if value is not None else ""))


def _sh_array(name: str, values: List[str]) -> str:
    if not values:
        return "%s=()" % name
    return "%s=(%s)" % (name, " ".join(_sh_quote(v) for v in values))


def _token_map(args: argparse.Namespace) -> Dict[str, str]:
    return {
        "PREFIX": str(getattr(args, "prefix", "") or ""),
        "BUILD_DIR": str(getattr(args, "build_dir", "") or ""),
        "SRC_DIR": str(getattr(args, "src_dir", "") or ""),
        "ABI": str(getattr(args, "abi", "") or ""),
        "ZIG_TARGET": str(getattr(args, "zig_target", "") or ""),
    }


def _tokens(values: List[str], mapping: Dict[str, str]) -> List[str]:
    return [expand_tokens(v, mapping) for v in values]


def emit_shell(
    manifest: Manifest, tool_id: str, abi: str, args: argparse.Namespace
) -> str:
    """Emit a bash snippet describing one (tool, abi) build context."""
    spec = manifest.spec_for(tool_id, abi)
    abi_spec = manifest.matrix.get(abi)  # type: ignore[union-attr]
    mapping = _token_map(args)
    mapping.setdefault("ZIG_TARGET", abi_spec.zig_target)
    if not mapping.get("ZIG_TARGET"):
        mapping["ZIG_TARGET"] = abi_spec.zig_target
    # ``${karch}`` lets a tool entry point at its per-ABI bundled kernel-arch
    # UAPI tree (see strace's ``uapi_include`` in tools.yml).
    mapping["karch"] = abi_spec.karch

    deps = manifest.resolve_deps(tool_id, abi)
    dep_ids = [d["id"] for d in deps]

    lines: List[str] = []
    lines.append("# --- adb-bin-box build context: %s / %s ---" % (tool_id, abi))
    lines.append(_sh_scalar("TOOL_ID", spec["id"]))
    lines.append(_sh_scalar("TOOL_NAME", spec["name"]))
    lines.append(_sh_scalar("TOOL_VERSION", spec["version"]))
    lines.append(_sh_scalar("TOOL_REPO", spec["repo"]))
    lines.append(_sh_scalar("TOOL_BIN", spec["bin"]))
    lines.append(_sh_scalar("TOOL_TIER", spec["tier"]))
    lines.append(_sh_scalar("TOOL_NOTES", spec["notes"]))
    lines.append(_sh_scalar("BUILD_SYSTEM", spec["build_system"]))
    lines.append(_sh_scalar("TOOL_SOURCE_TYPE", spec["source"]["type"]))
    lines.append(_sh_scalar("TOOL_SOURCE_URL", spec["source"]["url"] or ""))
    lines.append(_sh_scalar("TOOL_SOURCE_TAG", spec["source"]["tag"] or ""))
    lines.append(_sh_scalar("TOOL_STRIP_COMPONENTS", spec["source"]["strip_components"]))
    lines.append(_sh_scalar("TOOL_FEATURES", ",".join(spec["features"])))

    lines.append(_sh_scalar("ABI", abi))
    lines.append(_sh_scalar("ZIG_TARGET", abi_spec.zig_target))
    lines.append(_sh_scalar("AT_HOST", abi_spec.autotools_host or abi_spec.zig_target))
    lines.append(_sh_scalar("E_MACHINE", abi_spec.e_machine))
    lines.append(_sh_scalar("ABI_BITS", abi_spec.bits))
    lines.append(_sh_scalar("ABI_MACHINE_NAME", abi_spec.machine_name))
    lines.append(_sh_scalar("QEMU_BIN", abi_spec.qemu or ""))

    lines.append(
        _sh_array("CONFIGURE_FLAGS", _tokens(spec["configure"]["flags"], mapping))
    )
    cmd = spec["configure"]["command"]
    lines.append(
        _sh_scalar(
            "CONFIGURE_COMMAND",
            expand_tokens(cmd, mapping) if cmd else "",
        )
    )
    lines.append(
        _sh_array(
            "BOOTSTRAP_CMDS", _tokens(spec["configure"]["bootstrap"], mapping)
        )
    )

    lines.append(_sh_array("MAKE_TARGETS", spec["make"]["targets"]))
    lines.append(_sh_scalar("MAKE_INSTALL_TARGET", spec["make"]["install_target"]))
    lines.append(_sh_array("MAKE_INSTALL_VARS", spec["make"]["install_vars"]))
    lines.append(_sh_array("MAKE_ARGS", spec["make"]["args"]))

    for key in HOOK_KEYS:
        lines.append(
            _sh_array("HOOK_%s" % key.upper(), _tokens(spec["hooks"][key], mapping))
        )

    lines.append(_sh_array("PATCHES", spec["patches"]))
    # ``uapi_include`` roots become plain `-I` flags (see common.sh).  They go
    # through expand_tokens() like every other path-bearing field, and the result
    # is asserted '$'-free: a literal ``$SRC_DIR`` left in an emitted value would
    # silently become a bogus relative path in the compiler command line instead
    # of failing — the exact silent-miss class the landing gate exists for.
    uapi_include = _tokens(spec["uapi_include"], mapping)
    for entry in uapi_include:
        if "$" in entry:
            raise ManifestError(
                "tool %r abi %r: unresolved $ token in uapi_include entry %r"
                % (tool_id, abi, entry)
            )
    lines.append(_sh_array("UAPI_INCLUDE", uapi_include))

    art_paths = _tokens([a["path"] for a in spec["artifacts"]], mapping)
    lines.append(_sh_array("ARTIFACT_PATHS", art_paths))
    lines.append(
        _sh_array(
            "ARTIFACT_BINS",
            [a["bin_name"] or "" for a in spec["artifacts"]],
        )
    )
    lines.append(
        _sh_array(
            "ARTIFACT_STRIP",
            ["1" if a["strip"] else "0" for a in spec["artifacts"]],
        )
    )
    lines.append(
        _sh_array(
            "ARTIFACT_REQUIRED",
            ["1" if a["required"] else "0" for a in spec["artifacts"]],
        )
    )

    lines.append(_sh_array("SMOKE_ARGS", spec["smoke"]["args"]))
    lines.append(_sh_scalar("SMOKE_EXPECT_EXIT", spec["smoke"]["expect_exit"]))
    lines.append(_sh_scalar("SMOKE_CONTAINS", spec["smoke"]["contains"] or ""))

    env_kv = [
        "%s=%s" % (k, expand_tokens(v, mapping)) for k, v in spec["env"].items()
    ]
    lines.append(_sh_array("TOOL_ENV_KV", env_kv))

    lines.append(_sh_array("DEP_IDS", dep_ids))
    lines.append(
        _sh_scalar("DEFAULT_CFLAGS", str(manifest.defaults.get("cflags", DEFAULT_CFLAGS)))
    )
    lines.append(
        _sh_scalar("DEFAULT_LDFLAGS", str(manifest.defaults.get("ldflags", DEFAULT_LDFLAGS)))
    )
    lines.append("")
    return "\n".join(lines)


def emit_dep_shell(
    manifest: Manifest, dep_id: str, abi: str, args: argparse.Namespace
) -> str:
    """Emit a bash snippet describing one dependency build context."""
    raw = manifest._raw_dep(dep_id) if dep_id in manifest._raw_deps else None
    if raw is None:
        dep = manifest.dep(dep_id)
        spec = normalize_dep(dep, manifest.defaults, manifest.matrix)  # type: ignore[arg-type]
    else:
        override = (raw.get("abi_overrides") or {}).get(abi, {})
        merged = deep_merge(raw, override)
        spec = normalize_dep(merged, manifest.defaults, manifest.matrix)  # type: ignore[arg-type]
    abi_spec = manifest.matrix.get(abi)  # type: ignore[union-attr]
    mapping = _token_map(args)
    mapping["ZIG_TARGET"] = abi_spec.zig_target

    lines: List[str] = []
    lines.append("# --- adb-bin-box dep context: %s / %s ---" % (dep_id, abi))
    lines.append(_sh_scalar("DEP_ID", spec["id"]))
    lines.append(_sh_scalar("DEP_VERSION", spec["version"]))
    lines.append(_sh_scalar("DEP_REPO", spec["repo"]))
    lines.append(_sh_scalar("DEP_BUILD_SYSTEM", spec["build_system"]))
    lines.append(_sh_scalar("DEP_SOURCE_TYPE", spec["source"]["type"]))
    lines.append(_sh_scalar("DEP_SOURCE_URL", spec["source"]["url"] or ""))
    lines.append(_sh_scalar("DEP_SOURCE_TAG", spec["source"]["tag"] or ""))
    lines.append(_sh_scalar("DEP_STRIP_COMPONENTS", spec["source"]["strip_components"]))
    lines.append(_sh_array("DEP_CONFIGURE_FLAGS", _tokens(spec["configure"]["flags"], mapping)))
    dep_cmd = spec["configure"]["command"]
    lines.append(
        _sh_scalar("DEP_CONFIGURE_COMMAND", expand_tokens(dep_cmd, mapping) if dep_cmd else "")
    )
    lines.append(_sh_array("DEP_BOOTSTRAP_CMDS", _tokens(spec["configure"]["bootstrap"], mapping)))
    lines.append(_sh_array("DEP_MAKE_TARGETS", spec["make"]["targets"]))
    lines.append(_sh_scalar("DEP_MAKE_INSTALL_TARGET", spec["make"]["install_target"]))
    lines.append(_sh_array("DEP_MAKE_INSTALL_VARS", spec["make"]["install_vars"]))
    lines.append(_sh_array("DEP_MAKE_ARGS", spec["make"]["args"]))
    lines.append(_sh_array("DEP_PROVIDES", spec["provides"]))
    env_kv = ["%s=%s" % (k, expand_tokens(v, mapping)) for k, v in spec["env"].items()]
    lines.append(_sh_array("DEP_ENV_KV", env_kv))
    lines.append(_sh_scalar("DEP_NOTES", spec["notes"]))
    lines.append("")
    return "\n".join(lines)


def manifest_to_json(manifest: Manifest, tool_id: Optional[str] = None,
                     abi: Optional[str] = None) -> str:
    """Dump the (optionally filtered) manifest as JSON."""
    if tool_id is not None and abi is not None:
        payload: Any = manifest.spec_for(tool_id, abi)
    elif tool_id is not None:
        payload = manifest.tool(tool_id)
    else:
        payload = {
            "version": manifest.version,
            "defaults": manifest.defaults,
            "tools": manifest.tools,
            "deps": manifest.deps,
            "abis": manifest.matrix.to_dict() if hasattr(manifest.matrix, "to_dict") else {},
        }
    return json.dumps(payload, indent=2, sort_keys=False)


# --------------------------------------------------------------------------- #
# CLI                                                                         #
# --------------------------------------------------------------------------- #
def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="manifest.py",
        description="adb-bin-box manifest loader / validator / expander.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--tools", default="tools.yml", help="path to tools.yml")
    common.add_argument("--deps", default="deps.yml", help="path to deps.yml")

    p_validate = sub.add_parser("validate", parents=[common], help="validate manifests")
    p_validate.set_defaults(func=_cmd_validate)

    p_resolve = sub.add_parser(
        "resolve", parents=[common], help="print fully default-expanded manifest JSON"
    )
    p_resolve.add_argument("--out", default=None, help="write JSON here")
    p_resolve.set_defaults(func=_cmd_resolve)

    p_spec = sub.add_parser(
        "spec", parents=[common], help="print one tool spec (with abi overrides)"
    )
    p_spec.add_argument("--tool", required=True)
    p_spec.add_argument("--abi", required=True)
    p_spec.set_defaults(func=_cmd_spec)

    p_deps = sub.add_parser(
        "deps-for", parents=[common], help="print resolved dep ids for a tool"
    )
    p_deps.add_argument("--tool", required=True)
    p_deps.add_argument("--abi", default=None)
    p_deps.set_defaults(func=_cmd_deps_for)

    p_shell = sub.add_parser(
        "shell", parents=[common], help="emit bash build context for tool+abi"
    )
    _add_context_args(p_shell)
    p_shell.set_defaults(func=_cmd_shell)

    p_dep_shell = sub.add_parser(
        "dep-shell", parents=[common], help="emit bash build context for dep+abi"
    )
    p_dep_shell.add_argument("--dep", required=True)
    _add_context_args(p_dep_shell)
    p_dep_shell.set_defaults(func=_cmd_dep_shell)

    return parser


def _add_context_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--tool", default=None)
    parser.add_argument("--abi", required=True)
    parser.add_argument("--prefix", default="")
    parser.add_argument("--build-dir", default="")
    parser.add_argument("--src-dir", default="")
    parser.add_argument("--zig-target", default="")
    parser.add_argument("--out", default=None, help="write the snippet here")


def _cmd_validate(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.tools, args.deps)
    n_tools = len(manifest.enabled_tools())
    print(
        "OK tools.yml=%s deps.yml=%s version=%d tools=%d enabled=%d deps=%d abis=%d"
        % (
            args.tools,
            args.deps,
            manifest.version,
            len(manifest.tools),
            n_tools,
            len(manifest.deps),
            len(manifest.matrix.abis),  # type: ignore[union-attr]
        )
    )
    return 0


def _cmd_resolve(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.tools, args.deps)
    text = manifest_to_json(manifest)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
        print("wrote %s" % args.out)
    else:
        print(text)
    return 0


def _cmd_spec(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.tools, args.deps)
    print(manifest_to_json(manifest, args.tool, args.abi))
    return 0


def _cmd_deps_for(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.tools, args.deps)
    deps = manifest.resolve_deps(args.tool, args.abi)
    print(json.dumps([d["id"] for d in deps]))
    return 0


def _cmd_shell(args: argparse.Namespace) -> int:
    if not args.tool:
        raise ManifestError("shell sub-command requires --tool")
    manifest = load_manifest(args.tools, args.deps)
    text = emit_shell(manifest, args.tool, args.abi, args)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 0


def _cmd_dep_shell(args: argparse.Namespace) -> int:
    manifest = load_manifest(args.tools, args.deps)
    text = emit_dep_shell(manifest, args.dep, args.abi, args)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except ManifestError as exc:
        sys.stderr.write("MANIFEST ERROR: %s\n" % exc)
        return 1
    except OSError as exc:
        sys.stderr.write("IO ERROR: %s\n" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
