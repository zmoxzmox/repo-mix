#!/usr/bin/env python3
"""Plan, run, and aggregate the RepoPrompt CE worktree-startup live diagnostic.

The live subcommands require an already-running RepoPrompt CE DEBUG app and
rpce-cli-debug. This script never builds, installs, launches, stops, or
relaunches the app. Run ``plan`` and ``aggregate`` without contacting the app.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from typing import Any, Iterable


SCHEMA_VERSION = 1
DEBUG_TOOL = "__repoprompt_debug_diagnostics"
WORKSPACE_PREFIX = "RPCE 8E Bench "
DEFAULT_OUTPUT_ROOT = "/tmp/rpce-worktree-startup/v1"
BENCHMARK_GATE_KEY = "agent_mode.worktree_startup_benchmark_diagnostics_enabled"
OWNERSHIP_MARKER_NAME = ".rpce-worktree-startup-benchmark.json"
TERMINAL_STATES = {"completed", "failed", "cancelled", "canceled", "stopped", "expired"}
ROUTES = {
    "baseline": {"observe": False, "serve": False, "force_full": False, "expected": "fullCrawl"},
    "forced-full": {"observe": False, "serve": False, "force_full": True, "expected": "forcedFullCrawl"},
    "projected": {"observe": True, "serve": True, "force_full": False, "expected": "diffSeedServing"},
}
EXPECTED_ACTUAL_ROUTE_COUNTS = {
    "baseline": {"fullCrawl": 1},
    "forced-full": {"fullCrawl": 1},
    "projected": {"diffSeedServing": 1},
}
REQUIRED_GIT_FIELDS = {
    "available", "command_count", "families", "priorities", "queue_wait_us",
    "duration_us", "output_bytes", "cancelled_count",
}
REQUIRED_FILESYSTEM_FIELDS = {
    "available", "operation_count", "duration_us", "item_count",
}
REQUIRED_RESOURCE_FIELDS = {
    "baseline_resident_mb", "peak_resident_mb", "final_resident_mb",
    "peak_resident_delta_mb", "retained_resident_delta_mb",
    "baseline_physical_footprint_mb", "peak_physical_footprint_mb",
    "final_physical_footprint_mb", "peak_physical_footprint_delta_mb",
    "retained_physical_footprint_delta_mb", "physical_footprint_available",
    "session_cpu_ms", "session_user_cpu_ms", "session_system_cpu_ms",
    "average_core_utilization_percent", "peak_interval_core_utilization_percent",
    "sample_count", "duration_seconds",
}
AUTOMATED_SCENARIOS = [
    "linked-worktree",
    "parallel-1",
    "parallel-2",
    "parallel-4",
    "parallel-8",
]
CORRECTNESS_SCENARIOS = [
    "nested-inherited-worktree-agent",
    "selection-exact-root",
    "code-structure-exact-root",
    "cross-root-negative",
    "non-git-root",
    "watcher-create-edit-rename-delete",
    "secondary-ordinary-root-idle",
    "secondary-worktree-root-idle",
    "secondary-ordinary-root-in-flight",
    "secondary-worktree-root-in-flight",
    "active-agent-tab-binding",
]
METRICS = (
    "materialize_to_root_ready",
    "materialize_to_first_search",
    "materialize_to_first_read",
)
TOOL_METRICS = ("first_search", "first_read")
ALL_METRICS = METRICS + TOOL_METRICS


class BenchmarkError(RuntimeError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-") or "run"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def secure_write(path: Path, data: bytes, *, exclusive: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC)
    fd = os.open(path, flags, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(fd)


def save_json(path: Path, value: Any, *, exclusive: bool = False) -> None:
    secure_write(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode(), exclusive=exclusive)


def append_ndjson(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, canonical_json(value))
        os.fsync(fd)
    finally:
        os.close(fd)


def walk_json(value: Any) -> Iterable[Any]:
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk_json(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_json(child)
    elif isinstance(value, str) and value.lstrip().startswith(("{", "[")):
        try:
            yield from walk_json(json.loads(value))
        except json.JSONDecodeError:
            pass


def structured_json_objects(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from structured_json_objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from structured_json_objects(child)
    elif isinstance(value, str) and value.lstrip().startswith(("{", "[")):
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            return
        yield from structured_json_objects(parsed)


def canonicalize_evidence_path(path: str, root_path: str) -> str:
    candidate = Path(path).expanduser()
    if not candidate.is_absolute():
        candidate = Path(root_path) / candidate
    return str(candidate.resolve(strict=False))


def structured_mcp_record(value: Any, tool: str) -> dict[str, Any]:
    keys_by_tool = {
        "file_search": {"matches", "total_matches"},
        "read_file": {"path", "content"},
        "manage_selection": {"files"},
        "get_code_structure": {"files"},
    }
    required_any = keys_by_tool[tool]
    candidates: list[dict[str, Any]] = []
    for candidate in structured_json_objects(value):
        declared_tool = candidate.get("tool") or candidate.get("tool_name")
        if declared_tool is not None and str(declared_tool).split("__")[-1] != tool:
            continue
        typed_negative = (
            candidate.get("status") in {"not_found", "unavailable", "removed"}
            and (isinstance(candidate.get("issue"), dict) or isinstance(candidate.get("issue_code"), str))
        )
        if isinstance(candidate.get("status"), str) and (required_any & set(candidate) or typed_negative):
            candidates.append(candidate)
    if len(candidates) != 1:
        raise BenchmarkError(f"{tool} response requires exactly one structured status/root/file record")
    record = candidates[0]
    root = record.get("root")
    if not isinstance(root, dict):
        raise BenchmarkError(f"{tool} structured record omitted root")
    root_id = root.get("id") or root.get("root_id")
    root_path = root.get("path") or root.get("root_path")
    root_type = root.get("type") or root.get("root_type")
    if not all(isinstance(item, str) and item for item in (root_id, root_path, root_type)):
        raise BenchmarkError(f"{tool} structured record omitted canonical root identity/type")
    validate_uuid(root_id, f"{tool} root id")
    files_raw = record.get("matches") if tool == "file_search" else record.get("files")
    if tool == "read_file":
        if not isinstance(files_raw, list):
            files_raw = [] if not isinstance(record.get("path"), str) else [{
                "path": record.get("path"),
                "type": record.get("file_type") or record.get("type"),
                "content": record.get("content"),
            }]
    if not isinstance(files_raw, list):
        raise BenchmarkError(f"{tool} structured record omitted file records")
    files: list[dict[str, Any]] = []
    for file in files_raw:
        if not isinstance(file, dict) or not isinstance(file.get("path"), str):
            raise BenchmarkError(f"{tool} file record omitted path")
        file_type = file.get("type") or file.get("file_type") or file.get("kind")
        if not isinstance(file_type, str) or not file_type:
            raise BenchmarkError(f"{tool} file record omitted type")
        files.append({
            "path": canonicalize_evidence_path(file["path"], root_path),
            "type": file_type,
            "content": file.get("content") or file.get("text") or file.get("code"),
        })
    result = dict(record)
    result["root"] = {
        "id": str(uuid.UUID(root_id)).upper(),
        "path": str(Path(root_path).expanduser().resolve(strict=False)),
        "type": root_type,
    }
    result["files"] = files
    return result


def require_structured_success(
    value: Any,
    tool: str,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
    expected_file_path: str,
    expected_file_type: str,
    expected_content: str | None = None,
    require_only_file: bool = True,
) -> dict[str, Any]:
    if not call_succeeded(value):
        raise BenchmarkError(f"{tool} transport/tool call failed")
    record = structured_mcp_record(value, tool)
    if record.get("status") not in {"ok", "completed", "ready", "success"}:
        raise BenchmarkError(f"{tool} returned non-success status")
    expected_root = {
        "id": str(uuid.UUID(expected_root_id)).upper(),
        "path": str(Path(expected_root_path).resolve(strict=False)),
        "type": expected_root_type,
    }
    if record["root"] != expected_root:
        raise BenchmarkError(f"{tool} returned the wrong canonical root")
    expected_path = canonicalize_evidence_path(expected_file_path, expected_root_path)
    matches = [file for file in record["files"] if file["path"] == expected_path]
    if len(matches) != 1:
        raise BenchmarkError(f"{tool} did not return exactly the expected file")
    if require_only_file and len(record["files"]) != 1:
        raise BenchmarkError(f"{tool} returned cross-root or extra files")
    if matches[0]["type"] != expected_file_type:
        raise BenchmarkError(f"{tool} returned the wrong file type")
    if expected_content is not None and expected_content not in str(matches[0].get("content") or ""):
        raise BenchmarkError(f"{tool} expected file content missing")
    if tool == "file_search":
        count = record.get("total_matches")
        if not isinstance(count, int) or count < 1:
            raise BenchmarkError("file_search returned invalid match count")
    return record


def require_structured_removed(
    value: Any,
    tool: str,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
) -> dict[str, Any]:
    if not call_succeeded(value):
        raise BenchmarkError(f"{tool} removed-root check had transport/tool failure")
    record = structured_mcp_record(value, tool)
    if record.get("status") not in {"not_found", "unavailable", "removed"}:
        raise BenchmarkError(f"{tool} removed-root check lacked typed removed/unavailable status")
    issue = record.get("issue")
    issue_code = issue.get("code") if isinstance(issue, dict) else record.get("issue_code")
    if issue_code not in {"root_not_found", "root_removed", "root_unavailable", "git_root_unavailable"}:
        raise BenchmarkError(f"{tool} removed-root check lacked typed issue code")
    expected_id = str(uuid.UUID(expected_root_id)).upper()
    if record["root"] != {
        "id": expected_id, "path": str(Path(expected_root_path).resolve(strict=False)),
        "type": expected_root_type,
    }:
        raise BenchmarkError(f"{tool} removed-root check returned wrong root identity")
    if record["files"]:
        raise BenchmarkError(f"{tool} removed-root check returned stale files")
    return record


def structured_success_evidence(value: Any, tool: str, **expected: Any) -> dict[str, Any]:
    try:
        record = require_structured_success(value, tool, **expected)
        return {"ok": True, "status": record["status"], "root": record["root"], "files": record["files"]}
    except BenchmarkError as error:
        return {"ok": False, "error": str(error)}


def structured_removed_evidence(value: Any, tool: str, **expected: Any) -> dict[str, Any]:
    try:
        record = require_structured_removed(value, tool, **expected)
        return {"ok": True, "status": record["status"], "root": record["root"], "issue": record.get("issue")}
    except BenchmarkError as error:
        return {"ok": False, "error": str(error)}


def structured_empty_success_evidence(
    value: Any,
    tool: str,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
) -> dict[str, Any]:
    try:
        if not call_succeeded(value):
            raise BenchmarkError(f"{tool} transport/tool call failed")
        record = structured_mcp_record(value, tool)
        if record.get("status") not in {"ok", "completed", "ready", "success"}:
            raise BenchmarkError(f"{tool} returned non-success status")
        expected_root = {
            "id": str(uuid.UUID(expected_root_id)).upper(),
            "path": str(Path(expected_root_path).resolve(strict=False)),
            "type": expected_root_type,
        }
        if record["root"] != expected_root or record["files"]:
            raise BenchmarkError(f"{tool} empty result had wrong root or stale files")
        if tool == "file_search" and record.get("total_matches") != 0:
            raise BenchmarkError("file_search empty result had nonzero total_matches")
        return {"ok": True, "status": record["status"], "root": record["root"]}
    except BenchmarkError as error:
        return {"ok": False, "error": str(error)}


def find_value(value: Any, key: str) -> Any:
    for candidate in walk_json(value):
        if isinstance(candidate, dict) and key in candidate:
            return candidate[key]
    return None


def find_object(value: Any, key: str) -> dict[str, Any]:
    for candidate in walk_json(value):
        if isinstance(candidate, dict) and key in candidate:
            return candidate
    raise BenchmarkError(f"response omitted {key!r}")


def response_text(value: Any) -> str:
    chunks: list[str] = []
    for candidate in walk_json(value):
        if isinstance(candidate, dict) and isinstance(candidate.get("text"), str):
            chunks.append(candidate["text"])
    return "\n".join(chunks)


def response_session_id(value: Any) -> str:
    found = find_value(value, "session_id") or find_value(value, "sessionId")
    if not isinstance(found, str) or not found:
        raise BenchmarkError("agent response omitted session_id")
    return found


def response_context_id(value: Any) -> str | None:
    found = find_value(value, "context_id") or find_value(value, "tab_id")
    return found if isinstance(found, str) and found else None


def response_status(value: Any) -> str:
    found = find_value(value, "status") or find_value(value, "state")
    return str(found or "unknown").lower()


def response_worktree_paths(value: Any) -> list[str]:
    paths: set[str] = set()
    for candidate in walk_json(value):
        if not isinstance(candidate, dict):
            continue
        if any(key in candidate for key in ("worktree_id", "worktree_path", "worktree")):
            for key in ("path", "worktree_path"):
                path = candidate.get(key)
                if isinstance(path, str) and path.startswith("/"):
                    paths.add(path)
    return sorted(paths)


def git_work_records(value: Any) -> list[dict[str, Any]]:
    records = find_value(value, "git_invocations")
    if not isinstance(records, list):
        return []
    return [record for record in records if isinstance(record, dict)]


def new_records(before: list[dict[str, Any]], after: list[dict[str, Any]]) -> list[dict[str, Any]]:
    remaining = [canonical_json(record) for record in before]
    result: list[dict[str, Any]] = []
    for record in after:
        encoded = canonical_json(record)
        try:
            remaining.remove(encoded)
        except ValueError:
            result.append(record)
    return result


def runtime_root_identity(value: Any, expected_path: str) -> dict[str, str]:
    canonical = str(Path(expected_path).resolve(strict=False))
    matches: list[dict[str, str]] = []
    for candidate in structured_json_objects(value):
        raw_path = candidate.get("root_path") or candidate.get("path")
        raw_id = candidate.get("root_id") or candidate.get("id")
        raw_type = candidate.get("root_kind") or candidate.get("root_type") or candidate.get("type")
        if not all(isinstance(item, str) and item for item in (raw_path, raw_id, raw_type)):
            continue
        if str(Path(raw_path).resolve(strict=False)) != canonical:
            continue
        matches.append({
            "id": str(uuid.UUID(raw_id)).upper(), "path": canonical, "type": raw_type,
        })
    unique = {canonical_json(match) for match in matches}
    if len(unique) != 1:
        raise BenchmarkError(f"runtime snapshot did not contain exactly one root identity for {canonical}")
    return json.loads(next(iter(unique)))


def strict_telemetry_number(value: Any, *, positive: bool, label: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise BenchmarkError(f"{label} must be a numeric non-bool value")
    number = float(value)
    if not math.isfinite(number):
        raise BenchmarkError(f"{label} must be finite")
    if number < 0 or (positive and number == 0):
        qualifier = "positive" if positive else "non-negative"
        raise BenchmarkError(f"{label} must be {qualifier}")
    return number


def nearest_rank(values: Iterable[float], fraction: float) -> float | None:
    ordered = sorted(
        strict_telemetry_number(value, positive=False, label="percentile value")
        for value in values
    )
    if not ordered:
        return None
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def stats(
    values: Iterable[float], *, positive: bool = False, label: str = "telemetry value"
) -> dict[str, Any]:
    ordered = sorted(
        strict_telemetry_number(value, positive=positive, label=label)
        for value in values
    )
    if not ordered:
        return {"count": 0, "p50": None, "p95": None, "variance": None, "cv": None}
    mean = statistics.fmean(ordered)
    variance = statistics.variance(ordered) if len(ordered) > 1 else 0.0
    cv = math.sqrt(variance) / mean if mean else None
    return {
        "count": len(ordered),
        "p50": statistics.median(ordered),
        "p95": nearest_rank(ordered, 0.95),
        "variance": variance,
        "cv": cv,
        "reliability": "high" if cv is not None and cv <= 0.10 else "moderate" if cv is not None and cv <= 0.20 else "low",
        "min": ordered[0],
        "max": ordered[-1],
    }


def register_unique(value: Any, seen: set[Any], label: str) -> None:
    if value in seen:
        raise BenchmarkError(f"duplicate {label}: {value}")
    seen.add(value)


def validate_sample_ordinals(samples: list[dict[str, Any]], expected_count: int) -> None:
    if not positive_integer(expected_count):
        raise BenchmarkError("expected sample count must be a positive integer")
    raw_ordinals = [sample.get("ordinal") for sample in samples]
    if not all(positive_integer(ordinal) for ordinal in raw_ordinals):
        raise BenchmarkError("sample ordinals must be positive integers")
    ordinals = set(raw_ordinals)
    if len(samples) != expected_count or ordinals != set(range(1, expected_count + 1)):
        raise BenchmarkError("sample ordinal/accounting mismatch")


def cohort_accounting_valid(
    cohort: dict[str, Any], *, width: int, warmups: int, retained: int, invocations: int
) -> bool:
    return (
        invocations > 0
        and cohort.get("invocation_count") == invocations
        and cohort.get("attempted") == invocations * (warmups + retained) * width
        and cohort.get("valid_retained") == invocations * retained * width
        and cohort.get("invalid_attempted") == 0
    )


def run_local(command: list[str], cwd: Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    process = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if check and process.returncode:
        raise BenchmarkError(f"{' '.join(command)} failed: {process.stderr.strip()}")
    return process


def resolve_cli(raw: str | None) -> Path:
    candidates = [
        raw,
        os.environ.get("REPOPROMPT_DEBUG_CLI_INSTALL_PATH"),
        shutil.which("rpce-cli-debug"),
        str(Path.home() / "Library/Application Support/RepoPrompt CE/repoprompt_ce_cli_debug"),
    ]
    for candidate in candidates:
        if candidate:
            path = Path(candidate).expanduser()
            if path.is_file() and os.access(path, os.X_OK):
                return path.resolve(strict=True)
    raise BenchmarkError("rpce-cli-debug was not found")


def validate_uuid(value: str, label: str) -> str:
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError as error:
        raise BenchmarkError(f"{label} must be a UUID") from error


def repository_root() -> Path:
    return Path(__file__).resolve().parent.parent


def ownership_marker_path(root: Path) -> Path:
    return root / OWNERSHIP_MARKER_NAME


def create_marker_command(args: argparse.Namespace) -> int:
    if not args.confirm_disposable_root:
        raise BenchmarkError("create-marker requires --confirm-disposable-root")
    root = Path(args.root_path).expanduser().resolve(strict=True)
    if root == repository_root():
        raise BenchmarkError("the development checkout cannot be marked as a disposable benchmark root")
    marker = ownership_marker_path(root)
    payload = {
        "schema_version": SCHEMA_VERSION,
        "purpose": "rpce-worktree-startup-live-benchmark",
        "disposable": True,
        "workspace_id": validate_uuid(args.workspace_id, "workspace-id"),
        "root_id": validate_uuid(args.root_id, "root-id"),
        "canonical_root": str(root),
        "owner_token": validate_uuid(args.owner_token, "owner-token"),
        "created_at": utc_now(),
    }
    save_json(marker, payload, exclusive=True)
    print(marker)
    return 0


def load_ownership_marker(root: Path) -> tuple[Path, dict[str, Any], str]:
    marker_path = ownership_marker_path(root)
    raw = marker_path.read_bytes()
    marker = json.loads(raw)
    if not isinstance(marker, dict):
        raise BenchmarkError("benchmark ownership marker must be a JSON object")
    return marker_path, marker, sha256_bytes(raw)


def validate_ownership_marker(
    root: Path,
    *,
    workspace_id: str,
    root_id: str,
    owner_token: str | None = None,
    expected_sha256: str | None = None,
) -> tuple[Path, dict[str, Any], str]:
    if root.resolve() == repository_root():
        raise BenchmarkError("the development checkout is not a disposable benchmark target")
    marker_path, marker, digest = load_ownership_marker(root)
    expected = {
        "schema_version": SCHEMA_VERSION,
        "purpose": "rpce-worktree-startup-live-benchmark",
        "disposable": True,
        "workspace_id": workspace_id,
        "root_id": root_id,
        "canonical_root": str(root.resolve()),
    }
    for key, value in expected.items():
        if str(marker.get(key)).upper() != str(value).upper():
            raise BenchmarkError(f"benchmark ownership marker mismatch for {key}")
    validate_uuid(str(marker.get("owner_token") or ""), "marker owner-token")
    if owner_token is not None and str(marker.get("owner_token")).upper() != owner_token.upper():
        raise BenchmarkError("benchmark ownership marker owner token mismatch")
    if expected_sha256 is not None and digest != expected_sha256:
        raise BenchmarkError("benchmark ownership marker digest changed")
    return marker_path, marker, digest


def load_plan(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema_version") != SCHEMA_VERSION:
        raise BenchmarkError("unsupported plan schema")
    digest = value.get("plan_sha256")
    body = dict(value)
    body.pop("plan_sha256", None)
    if digest != sha256_bytes(canonical_json(body)):
        raise BenchmarkError("plan digest mismatch")
    return value


def plan_digest(value: dict[str, Any]) -> str:
    body = dict(value)
    body.pop("plan_sha256", None)
    return sha256_bytes(canonical_json(body))


def exact_scope(plan: dict[str, Any]) -> dict[str, Any]:
    scope = plan["scope"]
    return {
        "window_id": scope["window_id"],
        "workspace_id": scope["workspace_id"],
        "context_id": scope["context_id"],
        "benchmark_context_id": scope["context_id"],
        "root_id": scope["root_id"],
    }


@dataclass
class TimedCall:
    response: Any
    started_ns: int
    finished_ns: int
    returncode: int


class CLIRunner:
    def __init__(self, cli: Path, window_id: int, cwd: Path, artifact: Path | None = None) -> None:
        self.cli = cli
        self.window_id = window_id
        self.cwd = cwd
        self.artifact = artifact
        self.lock = threading.Lock()
        existing_ordinals: list[int] = []
        if artifact and (artifact / "raw").is_dir():
            for path in (artifact / "raw").glob("*.json"):
                prefix = path.name.split("-", 1)[0]
                if prefix.isdigit():
                    existing_ordinals.append(int(prefix))
        self.ordinal = max(existing_ordinals, default=-1) + 1

    def call(
        self,
        label: str,
        tool: str,
        payload: dict[str, Any],
        *,
        timeout: float = 300,
        check: bool = True,
    ) -> Any:
        return self.timed_call(label, tool, payload, timeout=timeout, check=check).response

    def timed_call(
        self,
        label: str,
        tool: str,
        payload: dict[str, Any],
        *,
        timeout: float = 300,
        check: bool = True,
    ) -> TimedCall:
        routed = dict(payload)
        routed.setdefault("_windowID", self.window_id)
        command = [
            str(self.cli), "--raw-json", "-w", str(self.window_id), "-c", tool,
            "-j", json.dumps(routed, separators=(",", ":"), sort_keys=True),
        ]
        started_ns = time.monotonic_ns()
        process = subprocess.run(command, cwd=self.cwd, text=True, capture_output=True, timeout=timeout)
        finished_ns = time.monotonic_ns()
        record = {
            "label": label,
            "tool": tool,
            "started_at": utc_now(),
            "started_monotonic_ns": started_ns,
            "finished_monotonic_ns": finished_ns,
            "returncode": process.returncode,
            "stdout": process.stdout,
            "stderr": process.stderr,
        }
        if self.artifact:
            with self.lock:
                ordinal = self.ordinal
                self.ordinal += 1
                save_json(self.artifact / "raw" / f"{ordinal:04d}-{safe_name(label)}.json", record, exclusive=True)
                append_ndjson(self.artifact / "raw-cli-calls.ndjson", record)
        if check and process.returncode:
            raise BenchmarkError(f"{label} failed ({process.returncode}): {process.stderr.strip()}")
        if not process.stdout.strip():
            response: Any = {}
        else:
            try:
                response = json.loads(process.stdout)
            except json.JSONDecodeError as error:
                if check:
                    raise BenchmarkError(f"{label} returned non-JSON stdout") from error
                response = {"unparsed_stdout": process.stdout, "returncode": process.returncode}
        if not check and process.returncode:
            response = {
                "_benchmark_cli_returncode": process.returncode,
                "_benchmark_response": response,
            }
        return TimedCall(response, started_ns, finished_ns, process.returncode)

    def describe(self, tool: str) -> str:
        process = subprocess.run(
            [str(self.cli), "describe", tool], cwd=self.cwd, text=True, capture_output=True, timeout=60
        )
        if process.returncode:
            raise BenchmarkError(f"describe {tool} failed: {process.stderr.strip()}")
        return process.stdout


def make_artifact(output_root: Path, label: str) -> Path:
    output_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    artifact = output_root / f"{stamp}-{safe_name(label)}-{uuid.uuid4().hex[:8]}"
    artifact.mkdir(mode=0o700)
    return artifact


def plan_command(args: argparse.Namespace) -> int:
    root = Path(args.root_path).expanduser().resolve(strict=True)
    read_path = Path(args.read_path)
    if read_path.is_absolute() or ".." in read_path.parts:
        raise BenchmarkError("read-path must be root-relative and remain inside the root")
    if not args.workspace_name.startswith(WORKSPACE_PREFIX):
        raise BenchmarkError(f"workspace-name must start with {WORKSPACE_PREFIX!r}")
    if args.asserted_file_count < 100_000:
        raise BenchmarkError("asserted-file-count must be at least 100000 for the large-workspace lane")
    if args.retained_samples < 3:
        raise BenchmarkError("retained-samples must be at least 3")
    if args.warmups < 1:
        raise BenchmarkError("warmups must be at least 1")
    if args.invocations_per_series < 1:
        raise BenchmarkError("invocations-per-series must be at least 1")
    marker_path, marker, marker_sha256 = validate_ownership_marker(
        root,
        workspace_id=validate_uuid(args.workspace_id, "workspace-id"),
        root_id=validate_uuid(args.root_id, "root-id"),
        owner_token=validate_uuid(args.owner_token, "owner-token"),
    )
    plan: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "created_at": utc_now(),
        "scope": {
            "workspace_name": args.workspace_name,
            "window_id": args.window_id,
            "workspace_id": validate_uuid(args.workspace_id, "workspace-id"),
            "context_id": validate_uuid(args.context_id, "context-id"),
            "root_id": validate_uuid(args.root_id, "root-id"),
            "root_path": str(root),
            "ownership_marker": str(marker_path),
            "ownership_marker_sha256": marker_sha256,
            "owner_token": marker["owner_token"],
        },
        "dataset": {
            "label": args.dataset_label,
            "asserted_file_count": args.asserted_file_count,
            "base_ref": args.base_ref,
            "search_marker": args.search_marker,
            "read_path": str(read_path),
            "read_marker": args.read_marker,
            "code_file_type": args.code_file_type,
        },
        "matrix": {
            "process_states": ["cold", "warm", "aged"],
            "checkout_kinds": ["linked-worktree"],
            "routes": list(ROUTES),
            "widths": [1, 2, 4, 8],
            "warmups_per_series": args.warmups,
            "retained_samples_per_series": args.retained_samples,
            "invocations_per_series": args.invocations_per_series,
            "automated_scenarios": AUTOMATED_SCENARIOS,
            "correctness_scenarios": CORRECTNESS_SCENARIOS,
            "required_external_evidence": [
                "cold-main-workspace-open-root-ready",
                "main-checkout-cold-warm-root-search-read",
                "fresh-process-provenance",
                "aged-process-session-and-thread-inventory",
                "host-sleep-and-thermal-validity",
            ],
        },
        "thresholds": {
            "correctness_mismatches": 0,
            "eligible_warm_fallbacks": 0,
            "projected_p95_improvement_minimum": 0.40,
            "other_p95_regression_maximum": 0.05,
            "peak_memory_regression_maximum": 0.10,
        },
        "synthetic_hooks": {
            "routine_entries": 100_000,
            "opt_in_entries": 1_000_000,
            "environment": "REPOPROMPT_NAMESPACE_MANIFEST_SCALE_ENTRY_COUNT",
            "test_filter": "RepoPromptTests.WorkspaceRootNamespaceManifestTests/testSyntheticHundredThousandEntriesRemainWithinConfiguredBatchBytes",
        },
        "scoreboard": "prompt-exports/optimize-content-addressed-codemaps-runs.md",
    }
    plan["plan_sha256"] = plan_digest(plan)
    output = Path(args.output).expanduser().resolve()
    save_json(output, plan, exclusive=True)
    print(output)
    return 0


def record_evidence_command(args: argparse.Namespace) -> int:
    plan = load_plan(Path(args.plan).expanduser().resolve(strict=True))
    required = set(plan["matrix"]["required_external_evidence"])
    if args.scenario not in required:
        raise BenchmarkError(f"scenario must be one of {sorted(required)}")
    details: dict[str, Any] = {}
    if args.details:
        value = json.loads(Path(args.details).expanduser().resolve(strict=True).read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise BenchmarkError("details must contain one JSON object")
        details = value
    evidence = {
        "schema_version": SCHEMA_VERSION,
        "plan_sha256": plan["plan_sha256"],
        "scenario": args.scenario,
        "status": args.status,
        "recorded_at": utc_now(),
        "details": details,
    }
    output = Path(args.output).expanduser().resolve()
    save_json(output, evidence, exclusive=True)
    print(output)
    return 0


def self_test_command(_args: argparse.Namespace) -> int:
    checks: dict[str, bool] = {}
    with tempfile.TemporaryDirectory(prefix="rpce-worktree-benchmark-self-test-") as raw:
        root = Path(raw).resolve()
        workspace_id = str(uuid.uuid4()).upper()
        root_id = str(uuid.uuid4()).upper()
        owner_token = str(uuid.uuid4()).upper()
        marker = {
            "schema_version": SCHEMA_VERSION,
            "purpose": "rpce-worktree-startup-live-benchmark",
            "disposable": True,
            "workspace_id": workspace_id,
            "root_id": root_id,
            "canonical_root": str(root),
            "owner_token": owner_token,
            "created_at": utc_now(),
        }
        save_json(ownership_marker_path(root), marker, exclusive=True)
        _, _, marker_digest = validate_ownership_marker(
            root, workspace_id=workspace_id, root_id=root_id, owner_token=owner_token
        )
        checks["ownership_marker"] = len(marker_digest) == 64

    correlation = str(uuid.uuid4()).upper()
    session = str(uuid.uuid4()).upper()
    fixture_root = Path("/tmp/rpce-benchmark-structured-fixture").resolve()
    fixture_file = fixture_root / "Fixture.swift"
    fixture_root_id = str(uuid.uuid4()).upper()
    fixture_root_record = {
        "id": fixture_root_id, "path": str(fixture_root), "type": "linkedWorktree",
    }
    marker = "RPCE_STRUCTURED_FIXTURE"

    def tool_record(tool: str, *, status: str = "ok") -> dict[str, Any]:
        base: dict[str, Any] = {"tool": tool, "status": status, "root": fixture_root_record}
        if tool == "file_search":
            base.update({
                "matches": [{"path": str(fixture_file), "type": "file", "content": marker}],
                "total_matches": 1,
            })
        elif tool == "read_file":
            base.update({"path": str(fixture_file), "file_type": "file", "content": marker})
        elif tool == "manage_selection":
            base["files"] = [{"path": str(fixture_file), "type": "file"}]
        else:
            base["files"] = [{"path": str(fixture_file), "type": "swift", "content": marker}]
        return base

    search_record = tool_record("file_search")
    read_record = tool_record("read_file")
    transcript = "".join((
        '<tool_call name="mcp__file_search">',
        html.escape(json.dumps({
            "pattern": marker, "regex": False,
            "filter": {"paths": [str(fixture_file)]},
        })),
        "</tool_call>",
        '<tool_result name="mcp__file_search" status="ok">',
        html.escape(json.dumps(search_record)), "</tool_result>",
        '<tool_call name="mcp__read_file">',
        html.escape(json.dumps({"path": str(fixture_file)})), "</tool_call>",
        '<tool_result name="mcp__read_file" status="ok">',
        html.escape(json.dumps(read_record)), "</tool_result>",
        "<assistant>RPCE_INHERITED_CHILD_OK</assistant>",
    ))
    transcript_evidence = verify_agent_file_tool_transcript(
        transcript, expected_output="RPCE_INHERITED_CHILD_OK", expected_marker=marker,
        expected_file_path=str(fixture_file), expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )
    checks["nested_structured_tool_records"] = transcript_evidence["call_count"] == 2
    try:
        verify_agent_file_tool_transcript(
            "<assistant>file_search read_file RPCE_INHERITED_CHILD_OK</assistant>",
            expected_output="RPCE_INHERITED_CHILD_OK", expected_marker=marker,
            expected_file_path=str(fixture_file), expected_root_id=fixture_root_id,
            expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        )
        checks["nested_prompt_text_rejected"] = False
    except BenchmarkError:
        checks["nested_prompt_text_rejected"] = True

    exact_selection = require_structured_success(
        tool_record("manage_selection"), "manage_selection",
        expected_root_id=fixture_root_id, expected_root_path=str(fixture_root),
        expected_root_type="linkedWorktree", expected_file_path=str(fixture_file),
        expected_file_type="file",
    )
    checks["structured_exact_root"] = exact_selection["root"] == fixture_root_record
    wrong_root = tool_record("get_code_structure")
    wrong_root["root"] = dict(fixture_root_record, id=str(uuid.uuid4()).upper())
    checks["structured_cross_root_rejected"] = not structured_success_evidence(
        wrong_root, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
        expected_file_path=str(fixture_file), expected_file_type="swift",
        expected_content=marker,
    )["ok"]
    removed_record = {
        "tool": "get_code_structure", "status": "unavailable", "root": fixture_root_record,
        "files": [], "issue": {"code": "git_root_unavailable"},
    }
    checks["structured_non_git_typed_status"] = structured_removed_evidence(
        removed_record, "get_code_structure", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )["ok"]
    removed_search = {
        "tool": "file_search", "status": "removed", "root": fixture_root_record,
        "matches": [], "total_matches": 0, "issue": {"code": "root_removed"},
    }
    checks["removed_root_typed_success"] = structured_removed_evidence(
        removed_search, "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )["ok"]
    removed_read = {
        "tool": "read_file", "status": "not_found", "root": fixture_root_record,
        "files": [], "issue": {"code": "root_not_found"},
    }
    checks["removed_read_typed_success"] = structured_removed_evidence(
        removed_read, "read_file", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )["ok"]
    checks["removed_root_transport_failure_rejected"] = not structured_removed_evidence(
        {"_benchmark_cli_returncode": 1, "_benchmark_response": removed_search},
        "file_search", expected_root_id=fixture_root_id,
        expected_root_path=str(fixture_root), expected_root_type="linkedWorktree",
    )["ok"]

    def export_fixture(route: str) -> dict[str, Any]:
        return {
            "sample": {
                "valid": True,
                "configured_route": ROUTES[route]["expected"],
                "correlation_id": correlation,
                "agent_session_id": session,
                "invocation": 1,
                "ordinal": 1,
                "route_counts": EXPECTED_ACTUAL_ROUTE_COUNTS[route],
                "fallback_counts": {},
                "durations_us": {metric: 100 for metric in ALL_METRICS},
            },
            "git": {
                "available": True, "command_count": 1, "families": {"test": 1},
                "priorities": {"test": 1}, "queue_wait_us": 0, "duration_us": 1,
                "output_bytes": 0, "cancelled_count": 0,
            },
            "work": {
                "filesystem": {
                    "available": True, "operation_count": 1, "duration_us": 1,
                    "item_count": 1,
                }
            },
        }

    for route in ROUTES:
        export = export_fixture(route)
        failures = validate_export(
            export, route, {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )
        checks[f"route_{route}"] = not failures
        export["sample"]["route_counts"] = {"wrong": 1}
        checks[f"route_{route}_negative"] = "actual_route_counts_mismatch" in validate_export(
            export, route, {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )

    def export_failures(export: dict[str, Any], route: str = "baseline") -> list[str]:
        return validate_export(
            export, route, {"search": True, "read": True},
            expected_correlation=correlation, expected_session=session,
            expected_invocation=1, expected_ordinal=1,
        )

    invalid_count_cases = {
        "sample_route_bool_count_rejected": ("route_counts", {"fullCrawl": True}, "invalid_route_counts"),
        "sample_route_string_count_rejected": ("route_counts", {"fullCrawl": "1"}, "invalid_route_counts"),
        "sample_route_float_count_rejected": ("route_counts", {"fullCrawl": 1.0}, "invalid_route_counts"),
        "sample_route_negative_count_rejected": ("route_counts", {"fullCrawl": -1}, "invalid_route_counts"),
        "sample_fallback_bool_count_rejected": ("fallback_counts", {"fallback": True}, "invalid_fallback_counts"),
    }
    for name, (field, value, expected_failure) in invalid_count_cases.items():
        export = export_fixture("baseline")
        export["sample"][field] = value
        checks[name] = expected_failure in export_failures(export)

    for name, value in {
        "sample_duration_bool_rejected": True,
        "sample_duration_string_rejected": "100",
        "sample_duration_nan_rejected": float("nan"),
        "sample_duration_inf_rejected": float("inf"),
        "sample_duration_negative_rejected": -1,
        "sample_duration_zero_rejected": 0,
    }.items():
        export = export_fixture("baseline")
        export["sample"]["durations_us"][METRICS[0]] = value
        checks[name] = "invalid_sample_durations" in export_failures(export)

    for name, value in {
        "sample_invocation_bool_rejected": True,
        "sample_invocation_string_rejected": "1",
    }.items():
        export = export_fixture("baseline")
        export["sample"]["invocation"] = value
        checks[name] = "sample_invocation_mismatch" in export_failures(export)

    checks["numeric_float_timings_accepted"] = not validate_export(
        {
            **export_fixture("baseline"),
            "git": {
                **export_fixture("baseline")["git"], "queue_wait_us": 0.5, "duration_us": 1.5,
            },
            "work": {"filesystem": {
                **export_fixture("baseline")["work"]["filesystem"], "duration_us": 1.25,
            }},
        },
        "baseline", {"search": True, "read": True}, expected_correlation=correlation,
        expected_session=session, expected_invocation=1, expected_ordinal=1,
    )
    checks["git_bool_timing_rejected"] = "invalid_git_duration_us" in validate_git_evidence({
        **export_fixture("baseline")["git"], "duration_us": True,
    })
    checks["filesystem_nan_timing_rejected"] = "invalid_filesystem_duration_us" in validate_filesystem_evidence({
        **export_fixture("baseline")["work"]["filesystem"], "duration_us": float("nan"),
    })

    def stats_rejects(value: Any, *, positive: bool = False) -> bool:
        try:
            stats([value], positive=positive, label="self-test timing")
        except BenchmarkError:
            return True
        return False

    checks["stats_bool_rejected"] = stats_rejects(True)
    checks["stats_numeric_string_rejected"] = stats_rejects("1")
    checks["stats_nan_rejected"] = stats_rejects(float("nan"))
    checks["stats_inf_rejected"] = stats_rejects(float("inf"))
    checks["stats_negative_rejected"] = stats_rejects(-1)
    checks["stats_required_positive_zero_rejected"] = stats_rejects(0, positive=True)
    checks["stats_finite_numeric_accepted"] = stats([0, 1.5])["p95"] == 1.5

    seen: set[Any] = set()
    register_unique(("warm", "projected", 1), seen, "cohort invocation")
    try:
        register_unique(("warm", "projected", 1), seen, "cohort invocation")
        checks["duplicate_rejected"] = False
    except BenchmarkError:
        checks["duplicate_rejected"] = True
    validate_sample_ordinals([{"ordinal": 1}, {"ordinal": 2}], 2)
    try:
        validate_sample_ordinals([{"ordinal": 1}, {"ordinal": 1}], 2)
        checks["ordinal_duplicate_rejected"] = False
    except BenchmarkError:
        checks["ordinal_duplicate_rejected"] = True
    for name, ordinal in {
        "ordinal_bool_rejected": True,
        "ordinal_string_rejected": "1",
        "ordinal_float_rejected": 1.0,
    }.items():
        try:
            validate_sample_ordinals([{"ordinal": ordinal}], 1)
        except BenchmarkError:
            checks[name] = True
        else:
            checks[name] = False
    identity_seen: set[str] = set()
    register_unique(correlation, identity_seen, "sample correlation identity")
    try:
        register_unique(correlation, identity_seen, "sample correlation identity")
        checks["duplicate_correlation_rejected"] = False
    except BenchmarkError:
        checks["duplicate_correlation_rejected"] = True
    session_seen: set[str] = set()
    register_unique(session, session_seen, "sample session identity")
    try:
        register_unique(session, session_seen, "sample session identity")
        checks["duplicate_session_rejected"] = False
    except BenchmarkError:
        checks["duplicate_session_rejected"] = True

    valid_accounting = {
        "invocation_count": 2, "attempted": 8, "valid_retained": 6,
        "invalid_attempted": 0,
    }
    checks["cohort_exact_accounting"] = cohort_accounting_valid(
        valid_accounting, width=1, warmups=1, retained=3, invocations=2
    )
    checks["cohort_extra_sample_rejected"] = not cohort_accounting_valid(
        dict(valid_accounting, attempted=9, valid_retained=7),
        width=1, warmups=1, retained=3, invocations=2,
    )
    checks["cohort_invalid_attempt_rejected"] = not cohort_accounting_valid(
        dict(valid_accounting, invalid_attempted=1),
        width=1, warmups=1, retained=3, invocations=2,
    )

    resource_fixture = {
        "baseline_resident_mb": 100.0, "peak_resident_mb": 120.0,
        "final_resident_mb": 110.0, "peak_resident_delta_mb": 20.0,
        "retained_resident_delta_mb": 10.0,
        "baseline_physical_footprint_mb": 80.0, "peak_physical_footprint_mb": 88.0,
        "final_physical_footprint_mb": 82.0, "peak_physical_footprint_delta_mb": 8.0,
        "retained_physical_footprint_delta_mb": 2.0,
        "physical_footprint_available": True,
        "session_cpu_ms": 30.0, "session_user_cpu_ms": 20.0,
        "session_system_cpu_ms": 10.0, "average_core_utilization_percent": 25.0,
        "peak_interval_core_utilization_percent": 50.0,
        "sample_count": 3, "duration_seconds": 1.0,
    }
    checks["resource_values_validated"] = not validate_resource_evidence(resource_fixture)
    checks["resource_core_range_rejected"] = "invalid_resource_core_utilization" in validate_resource_evidence(
        dict(resource_fixture, peak_interval_core_utilization_percent=10.0)
    )
    checks["git_family_count_rejected"] = "invalid_git_family_counts" in validate_git_evidence({
        "available": True, "command_count": 2, "families": {"status": 1},
        "priorities": {"normal": 2}, "queue_wait_us": 0, "duration_us": 1,
        "output_bytes": 0, "cancelled_count": 0,
    })
    checks["filesystem_item_type_rejected"] = "invalid_filesystem_item_count" in validate_filesystem_evidence({
        "available": True, "operation_count": 1, "duration_us": 1, "item_count": "1",
    })

    checks["memory_absolute"] = math.isclose(
        absolute_memory_regression([100.0, 100.0], [110.0, 110.0]) or -1,
        0.10,
        rel_tol=1e-9,
    )
    checks["memory_zero_rejected"] = absolute_memory_regression([0.0], [10.0]) is None
    checks["memory_negative_rejected"] = absolute_memory_regression([-1.0], [10.0]) is None

    run_cleanup = [
        {"action": "terminalize_agent", "terminal": True},
        {"action": "remove_worktree", "removed": True},
        {"action": "stop_memory_sampler", "ok": True, "verified_stopped": True},
        {"action": "restore_route", "ok": True},
        {"action": "reset_diagnostics", "ok": True},
        {"action": "preserve_benchmark_setting", "ok": True},
        {"action": "restore_workspace_roots", "ok": True},
    ]
    checks["cleanup_complete"] = validate_cleanup_evidence(
        run_cleanup, run_artifact=True, expected_agent_count=1, expected_worktree_count=1
    )
    checks["cleanup_missing_rejected"] = not validate_cleanup_evidence(
        run_cleanup[:-1], run_artifact=True, expected_agent_count=1, expected_worktree_count=1
    )
    checks["cleanup_memory_unverified_rejected"] = not validate_cleanup_evidence(
        [dict(item, verified_stopped=False) if item["action"] == "stop_memory_sampler" else item for item in run_cleanup],
        run_artifact=True, expected_agent_count=1, expected_worktree_count=1,
    )
    if not all(checks.values()):
        raise BenchmarkError(f"self-test failed: {[name for name, ok in checks.items() if not ok]}")
    print(json.dumps({"status": "completed", "checks": checks}, indent=2, sort_keys=True))
    return 0


def verify_scope(runner: CLIRunner, plan: dict[str, Any]) -> dict[str, Any]:
    scope = plan["scope"]
    payload = {
        "op": "worktree_startup_benchmark",
        "action": "scope",
        "window_id": scope["window_id"],
        "workspace_id": scope["workspace_id"],
        "context_id": scope["context_id"],
        "benchmark_context_id": scope["context_id"],
        "expected_root_path": scope["root_path"],
    }
    response = runner.call("scope", DEBUG_TOOL, payload)
    actual = find_object(response, "root_id")
    expected = {
        "window_id": scope["window_id"],
        "workspace_id": scope["workspace_id"],
        "context_id": scope["context_id"],
        "root_id": scope["root_id"],
    }
    for key, value in expected.items():
        if str(actual.get(key)).upper() != str(value).upper():
            raise BenchmarkError(f"scope mismatch for {key}")
    return actual


def workspace_inventory_record(value: Any, workspace_id: str) -> dict[str, Any]:
    matches: list[dict[str, Any]] = []
    for candidate in walk_json(value):
        if not isinstance(candidate, dict):
            continue
        candidate_id = candidate.get("id") or candidate.get("workspace_id")
        if isinstance(candidate_id, str) and candidate_id.upper() == workspace_id.upper():
            matches.append(candidate)
    if len(matches) != 1:
        raise BenchmarkError("workspace inventory did not contain exactly one planned workspace identity")
    return matches[0]


def workspace_root_paths(record: dict[str, Any]) -> list[str]:
    for key in ("repo_paths", "repoPaths", "all_repo_paths", "allRepoPaths", "folder_paths"):
        value = record.get(key)
        if isinstance(value, list) and all(isinstance(item, str) for item in value):
            return [str(Path(item).expanduser().resolve()) for item in value]
    raise BenchmarkError("workspace inventory omitted root paths")


def verify_disposable_target(
    runner: CLIRunner,
    plan: dict[str, Any],
    *,
    require_only_planned_root: bool,
) -> dict[str, Any]:
    scope = plan["scope"]
    root = Path(scope["root_path"]).resolve(strict=True)
    validate_ownership_marker(
        root,
        workspace_id=scope["workspace_id"],
        root_id=scope["root_id"],
        owner_token=scope["owner_token"],
        expected_sha256=scope["ownership_marker_sha256"],
    )
    inventory = runner.call(
        "workspace-identity", "manage_workspaces", {"action": "list", "include_hidden": True}
    )
    record = workspace_inventory_record(inventory, scope["workspace_id"])
    if record.get("name") != scope["workspace_name"]:
        raise BenchmarkError("planned workspace identity was renamed or substituted")
    roots = workspace_root_paths(record)
    planned_root = str(root)
    if planned_root not in roots:
        raise BenchmarkError("planned root is not owned by the planned workspace identity")
    if require_only_planned_root and roots != [planned_root]:
        raise BenchmarkError("benchmark workspace must contain exactly the planned root before/after the campaign")
    return {"workspace_id": scope["workspace_id"], "workspace_name": record.get("name"), "roots": roots}


def require_benchmark_gate(runner: CLIRunner) -> None:
    response = runner.call(
        "benchmark-gate-status", "app_settings", {"op": "get", "key": BENCHMARK_GATE_KEY}
    )
    enabled: bool | None = None
    for candidate in walk_json(response):
        if isinstance(candidate, dict) and candidate.get("key") == BENCHMARK_GATE_KEY:
            value = candidate.get("value")
            if isinstance(value, bool):
                enabled = value
                break
    if enabled is not True:
        raise BenchmarkError(
            f"DEBUG benchmark gate {BENCHMARK_GATE_KEY!r} must be explicitly enabled before the campaign"
        )


def preflight_command(args: argparse.Namespace) -> int:
    if not args.confirm_live_debug_app:
        raise BenchmarkError("pass --confirm-live-debug-app after verifying the dedicated DEBUG app is already running")
    plan_path = Path(args.plan).expanduser().resolve(strict=True)
    plan = load_plan(plan_path)
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"])
    artifact = make_artifact(Path(args.output_root), "preflight")
    runner = CLIRunner(cli, plan["scope"]["window_id"], root, artifact)
    schemas: dict[str, str] = {}
    for tool in (
        "bind_context", "manage_workspaces", "agent_run", "agent_manage", "manage_worktree",
        "file_search", "read_file", "manage_selection", "get_code_structure", "file_actions",
        "apply_edits", "app_settings", DEBUG_TOOL,
    ):
        schema = runner.describe(tool)
        schemas[tool] = sha256_bytes(schema.encode())
        secure_write(artifact / "schemas" / f"{tool}.txt", schema.encode(), exclusive=True)
    if "_worktree_startup_benchmark_token" not in (artifact / "schemas" / "agent_run.txt").read_text():
        raise BenchmarkError("agent_run schema omitted the DEBUG benchmark token")
    if "remove_folder" not in (artifact / "schemas" / "manage_workspaces.txt").read_text():
        raise BenchmarkError("manage_workspaces schema omitted remove_folder")
    verified = verify_scope(runner, plan)
    require_benchmark_gate(runner)
    target = verify_disposable_target(runner, plan, require_only_planned_root=True)
    summary = {
        "schema_version": SCHEMA_VERSION,
        "status": "completed",
        "plan_sha256": plan["plan_sha256"],
        "cli": str(cli),
        "cli_sha256": sha256_bytes(cli.read_bytes()),
        "schema_sha256": schemas,
        "scope": verified,
        "disposable_target": target,
        "artifact_directory": str(artifact),
    }
    save_json(artifact / "summary.json", summary, exclusive=True)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


def diagnostic_payload(plan: dict[str, Any], action: str, **extra: Any) -> dict[str, Any]:
    return {"op": "worktree_startup_benchmark", "action": action, **exact_scope(plan), **extra}


def set_route(runner: CLIRunner, plan: dict[str, Any], route: str) -> tuple[str, Any]:
    config = ROUTES[route]
    response = runner.call(
        f"set-route-{route}", DEBUG_TOOL,
        diagnostic_payload(plan, "set_flags", expires_seconds=900, **{key: config[key] for key in ("observe", "serve", "force_full")}),
    )
    control_id = find_value(response, "control_id")
    if not isinstance(control_id, str):
        raise BenchmarkError(f"{route} control omitted control_id")
    if route == "projected" and find_value(response, "base_snapshot_prepared") is not True:
        raise BenchmarkError("projected route did not prepare a base snapshot")
    return control_id, response


def arm_sample(
    runner: CLIRunner,
    plan: dict[str, Any],
    control_id: str,
    route: str,
    process_state: str,
    invocation: int,
    ordinal: int,
    warmup: bool,
    branch: str,
) -> tuple[str, str]:
    scenario = "aged" if process_state == "aged" else "parallel" if ordinal > 1 else "clean_same_tree"
    response = runner.call(
        f"arm-{route}-{ordinal}", DEBUG_TOOL,
        diagnostic_payload(
            plan, "arm", control_id=control_id, scenario=scenario, invocation=invocation,
            ordinal=ordinal, warmup=warmup, expires_seconds=900,
            worktree_base_ref=plan["dataset"]["base_ref"],
            worktree_branch=branch,
        ),
    )
    token, correlation = find_value(response, "token"), find_value(response, "correlation_id")
    if not isinstance(token, str) or not isinstance(correlation, str):
        raise BenchmarkError("arm response omitted token or correlation_id")
    return token, correlation


def start_agent(
    runner: CLIRunner,
    plan: dict[str, Any],
    route: str,
    token: str,
    invocation: int,
    ordinal: int,
    label: str,
    branch: str,
) -> Any:
    return runner.call(
        f"agent-start-{ordinal}", "agent_run",
        {
            "op": "start", "model_id": "explore", "detach": True,
            "message": "Reply exactly RPCE_WORKTREE_STARTUP_READY and stop. Do not edit files or invoke tools.",
            "session_name": f"RPCE startup {route} {ordinal}",
            "worktree_create": True, "worktree_branch": branch,
            "worktree_base_ref": plan["dataset"]["base_ref"],
            "worktree_label": f"RPCE startup {label} {ordinal}",
            "context_id": plan["scope"]["context_id"],
            "_worktree_startup_benchmark_token": token,
        },
        timeout=180,
    )


def mark(runner: CLIRunner, plan: dict[str, Any], correlation: str, phase: str) -> None:
    runner.call(
        f"mark-{phase}", DEBUG_TOOL,
        diagnostic_payload(plan, "mark", correlation_id=correlation, mark=phase),
    )


def first_search_read(
    runner: CLIRunner,
    plan: dict[str, Any],
    correlation: str,
    context_id: str | None,
) -> dict[str, bool]:
    routed = {"context_id": context_id} if context_id else {}
    mark(runner, plan, correlation, "first_search_started")
    search = runner.call(
        "first-search", "file_search",
        {
            "pattern": plan["dataset"]["search_marker"], "regex": False, "mode": "content",
            "filter": {"paths": [plan["dataset"]["read_path"]]}, "max_results": 20,
            **routed,
        },
    )
    mark(runner, plan, correlation, "first_search_completed")
    mark(runner, plan, correlation, "first_read_started")
    read = runner.call(
        "first-read", "read_file",
        {"path": plan["dataset"]["read_path"], "start_line": 1, "limit": 80, **routed},
    )
    mark(runner, plan, correlation, "first_read_completed")
    return {
        "search_marker_present": plan["dataset"]["search_marker"] in response_text(search),
        "read_marker_present": plan["dataset"]["read_marker"] in response_text(read),
    }


def nonnegative_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def positive_integer(value: Any) -> bool:
    return nonnegative_integer(value) and value > 0


def finite_number(value: Any, *, positive: bool = False) -> bool:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    number = float(value)
    return math.isfinite(number) and (number > 0 if positive else number >= 0)


def validate_count_breakdown(value: Any, expected_total: int) -> bool:
    return (
        isinstance(value, dict)
        and all(isinstance(key, str) and key for key in value)
        and all(nonnegative_integer(count) for count in value.values())
        and sum(value.values()) == expected_total
        and (expected_total == 0 or bool(value))
    )


def validate_named_counts(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and all(isinstance(key, str) and key for key in value)
        and all(nonnegative_integer(count) for count in value.values())
    )


def validate_git_evidence(value: Any) -> list[str]:
    if not isinstance(value, dict) or not REQUIRED_GIT_FIELDS <= set(value):
        return ["incomplete_git_evidence"]
    failures: list[str] = []
    count = value.get("command_count")
    if value.get("available") is not True:
        failures.append("git_evidence_unavailable")
    if not nonnegative_integer(count):
        failures.append("invalid_git_command_count")
        return failures
    if not validate_count_breakdown(value.get("families"), count):
        failures.append("invalid_git_family_counts")
    if not validate_count_breakdown(value.get("priorities"), count):
        failures.append("invalid_git_priority_counts")
    for field in ("queue_wait_us", "duration_us"):
        if not finite_number(value.get(field)):
            failures.append(f"invalid_git_{field}")
    for field in ("output_bytes", "cancelled_count"):
        if not nonnegative_integer(value.get(field)):
            failures.append(f"invalid_git_{field}")
    cancelled = value.get("cancelled_count")
    if nonnegative_integer(cancelled) and cancelled > count:
        failures.append("invalid_git_cancelled_count")
    return failures


def validate_filesystem_evidence(value: Any) -> list[str]:
    if not isinstance(value, dict) or not REQUIRED_FILESYSTEM_FIELDS <= set(value):
        return ["incomplete_filesystem_evidence"]
    failures: list[str] = []
    for field in ("operation_count", "item_count"):
        if not nonnegative_integer(value.get(field)):
            failures.append(f"invalid_filesystem_{field}")
    if not finite_number(value.get("duration_us")):
        failures.append("invalid_filesystem_duration_us")
    operation_count = value.get("operation_count")
    expected_available = nonnegative_integer(operation_count) and operation_count > 0
    if not isinstance(value.get("available"), bool) or value.get("available") != expected_available:
        failures.append("invalid_filesystem_availability")
    return failures


def validate_resource_evidence(value: Any) -> list[str]:
    if not isinstance(value, dict) or not REQUIRED_RESOURCE_FIELDS <= set(value):
        return ["incomplete_resource_evidence"]
    failures: list[str] = []
    if value.get("physical_footprint_available") is not True:
        failures.append("physical_footprint_unavailable")
    for family in ("resident", "physical_footprint"):
        baseline = value.get(f"baseline_{family}_mb")
        peak = value.get(f"peak_{family}_mb")
        final = value.get(f"final_{family}_mb")
        peak_delta = value.get(f"peak_{family}_delta_mb")
        retained_delta = value.get(f"retained_{family}_delta_mb")
        if not all(finite_number(item, positive=True) for item in (baseline, peak, final)):
            failures.append(f"invalid_{family}_absolute_mb")
            continue
        if not all(
            isinstance(item, (int, float)) and not isinstance(item, bool) and math.isfinite(float(item))
            for item in (peak_delta, retained_delta)
        ):
            failures.append(f"invalid_{family}_delta_mb")
            continue
        if float(peak) < max(float(baseline), float(final)):
            failures.append(f"invalid_{family}_peak_mb")
        tolerance = 1e-6 * max(1.0, abs(float(peak)), abs(float(final)), abs(float(baseline)))
        if not math.isclose(float(peak_delta), float(peak) - float(baseline), abs_tol=tolerance):
            failures.append(f"inconsistent_{family}_peak_delta")
        if not math.isclose(float(retained_delta), float(final) - float(baseline), abs_tol=tolerance):
            failures.append(f"inconsistent_{family}_retained_delta")
    for field in (
        "session_cpu_ms", "session_user_cpu_ms", "session_system_cpu_ms",
        "average_core_utilization_percent", "peak_interval_core_utilization_percent",
        "duration_seconds",
    ):
        if not finite_number(value.get(field), positive=field == "duration_seconds"):
            failures.append(f"invalid_resource_{field}")
    if not nonnegative_integer(value.get("sample_count")) or value.get("sample_count", 0) < 2:
        failures.append("invalid_resource_sample_count")
    if all(finite_number(value.get(field)) for field in ("session_cpu_ms", "session_user_cpu_ms", "session_system_cpu_ms")):
        if not math.isclose(
            float(value["session_cpu_ms"]),
            float(value["session_user_cpu_ms"]) + float(value["session_system_cpu_ms"]),
            rel_tol=1e-6, abs_tol=1e-6,
        ):
            failures.append("inconsistent_resource_cpu_total")
    average = value.get("average_core_utilization_percent")
    peak = value.get("peak_interval_core_utilization_percent")
    if finite_number(average) and finite_number(peak) and float(peak) < float(average):
        failures.append("invalid_resource_core_utilization")
    return failures


def validate_export(
    export: dict[str, Any],
    route: str,
    correctness: dict[str, bool],
    *,
    expected_correlation: str,
    expected_session: str,
    expected_invocation: int,
    expected_ordinal: int,
) -> list[str]:
    failures: list[str] = []
    sample = find_value(export, "sample")
    if not isinstance(sample, dict):
        return ["missing_sample"]
    if sample.get("valid") is not True:
        failures.append("diagnostic_invalid")
    if sample.get("configured_route") != ROUTES[route]["expected"]:
        failures.append("configured_route_mismatch")
    string_identity_expectations = {
        "correlation_id": expected_correlation,
        "agent_session_id": expected_session,
    }
    for key, expected in string_identity_expectations.items():
        if not isinstance(sample.get(key), str) or sample[key].upper() != expected.upper():
            failures.append(f"sample_{key}_mismatch")
    for key, expected in (("invocation", expected_invocation), ("ordinal", expected_ordinal)):
        if not positive_integer(sample.get(key)) or sample[key] != expected:
            failures.append(f"sample_{key}_mismatch")
    route_counts = sample.get("route_counts")
    fallbacks = sample.get("fallback_counts")
    if not validate_named_counts(route_counts):
        failures.append("invalid_route_counts")
    elif route_counts != EXPECTED_ACTUAL_ROUTE_COUNTS[route]:
        failures.append("actual_route_counts_mismatch")
    if not validate_named_counts(fallbacks):
        failures.append("invalid_fallback_counts")
    elif fallbacks != {}:
        failures.append("unexpected_fallback")
    if not all(correctness.values()):
        failures.append("content_oracle_mismatch")
    durations = sample.get("durations_us")
    if not isinstance(durations, dict) or not all(isinstance(key, str) and key for key in durations):
        failures.append("invalid_sample_durations")
        durations = {}
    elif any(not finite_number(value, positive=True) for value in durations.values()):
        failures.append("invalid_sample_durations")
    for metric in ALL_METRICS:
        if metric not in durations:
            failures.append(f"missing_{metric}")
    git = find_value(export, "git")
    failures.extend(validate_git_evidence(git))
    work = find_value(export, "work")
    filesystem = work.get("filesystem") if isinstance(work, dict) else None
    failures.extend(validate_filesystem_evidence(filesystem))
    return failures


def terminalize(runner: CLIRunner, session_id: str) -> str:
    response = runner.call(
        f"wait-{session_id[:8]}", "agent_run", {"op": "wait", "session_id": session_id, "timeout": 120},
        timeout=150, check=False,
    )
    status = response_status(response)
    if status not in TERMINAL_STATES:
        runner.call(
            f"cancel-{session_id[:8]}", "agent_run", {"op": "cancel", "session_id": session_id},
            timeout=30, check=False,
        )
        response = runner.call(
            f"settle-{session_id[:8]}", "agent_run", {"op": "wait", "session_id": session_id, "timeout": 30},
            timeout=45, check=False,
        )
        status = response_status(response)
    return status


def worktree_branch(path: Path, repo: Path) -> str | None:
    process = run_local(["git", "-C", str(path), "branch", "--show-current"], repo, check=False)
    value = process.stdout.strip()
    return value if process.returncode == 0 and value else None


def discover_owned_worktree(response: Any, repo: Path, expected_branch: str) -> Path:
    matches: list[Path] = []
    for raw_path in response_worktree_paths(response):
        candidate = Path(raw_path)
        if candidate.exists() and worktree_branch(candidate, repo) == expected_branch:
            matches.append(candidate.resolve())
    unique = sorted(set(matches))
    if len(unique) != 1:
        raise BenchmarkError(
            f"agent response did not identify exactly one worktree on owned branch {expected_branch!r}"
        )
    return unique[0]


def clean_owned_worktree(
    repo: Path,
    path: str,
    terminal: bool,
    *,
    expected_branch: str | None = None,
    expected_path: str | None = None,
) -> dict[str, Any]:
    candidate = Path(path)
    result: dict[str, Any] = {
        "action": "remove_worktree", "path": path, "removed": False, "reason": None,
    }
    if not terminal:
        result["reason"] = "session_nonterminal"
        return result
    if not candidate.exists():
        result["reason"] = "already_absent"
        return result
    if expected_path is not None and candidate.resolve() != Path(expected_path).resolve():
        result["reason"] = "ownership_path_mismatch"
        return result
    if expected_branch is None and expected_path is None:
        result["reason"] = "ownership_unproven"
        return result
    if expected_branch is not None and worktree_branch(candidate, repo) != expected_branch:
        result["reason"] = "ownership_branch_mismatch"
        return result
    listed = run_local(["git", "worktree", "list", "--porcelain"], repo).stdout
    if f"worktree {candidate.resolve()}\n" not in listed:
        result["reason"] = "not_registered"
        return result
    dirty = run_local(
        ["git", "-C", str(candidate), "status", "--porcelain=v1", "--untracked-files=all"], repo, check=False
    ).stdout.strip()
    if dirty:
        result["reason"] = "dirty"
        return result
    removal = run_local(["git", "worktree", "remove", str(candidate)], repo, check=False)
    result["removed"] = removal.returncode == 0
    result["reason"] = None if result["removed"] else "git_worktree_remove_failed"
    return result


def run_command(args: argparse.Namespace) -> int:
    if not args.confirm_live_debug_app or not args.confirm_process_state:
        raise BenchmarkError("run requires --confirm-live-debug-app and --confirm-process-state")
    plan_path = Path(args.plan).expanduser().resolve(strict=True)
    plan = load_plan(plan_path)
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"])
    artifact = make_artifact(Path(args.output_root), f"{args.process_state}-{args.route}-w{args.width}")
    runner = CLIRunner(cli, plan["scope"]["window_id"], root, artifact)
    save_json(artifact / "plan.json", plan, exclusive=True)
    state: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION, "plan_sha256": plan["plan_sha256"], "sessions": [],
        "worktrees": [], "control_id": None, "scope_reset": False,
        "benchmark_gate_expected_enabled": True,
    }
    save_json(artifact / "state.json", state)
    verify_scope(runner, plan)
    require_benchmark_gate(runner)
    verify_disposable_target(runner, plan, require_only_planned_root=True)
    if args.process_state == "aged":
        inventory = runner.call("aged-session-inventory", "agent_manage", {"op": "list_sessions", "limit": 500})
        session_count = sum(1 for item in walk_json(inventory) if isinstance(item, dict) and "session_id" in item)
        if session_count < args.minimum_aged_sessions:
            raise BenchmarkError(f"aged cohort requires at least {args.minimum_aged_sessions} existing sessions; found {session_count}")
    control_id, control_response = set_route(runner, plan, args.route)
    state["control_id"] = control_id
    state["control_response"] = control_response
    save_json(artifact / "state.json", state)
    runner.call(
        "memory-start", DEBUG_TOOL,
        {"op": "large_workspace_memory", "action": "start", "label": artifact.name, "interval_ms": 100, "reset": True, "benchmark_gate": True},
    )
    invocation = args.invocation
    sample_records: list[dict[str, Any]] = []
    operational_error: str | None = None
    try:
        total_groups = args.warmups + args.samples
        global_ordinal = 0
        for group in range(total_groups):
            warmup = group < args.warmups
            armed: list[tuple[int, str, str, str]] = []
            for member in range(args.width):
                global_ordinal += 1
                branch = safe_name(
                    f"rpce-bench-{artifact.name}-i{invocation}-o{global_ordinal}"
                )[:120]
                token, correlation = arm_sample(
                    runner, plan, control_id, args.route, args.process_state,
                    invocation, global_ordinal, warmup, branch,
                )
                armed.append((global_ordinal, token, correlation, branch))
            starts: dict[int, Any] = {}
            with ThreadPoolExecutor(max_workers=args.width) as pool:
                futures = {
                    pool.submit(
                        start_agent, runner, plan, args.route, token, invocation, ordinal,
                        f"{artifact.name}-{group}", branch,
                    ): ordinal
                    for ordinal, token, _, branch in armed
                }
                for future in as_completed(futures):
                    starts[futures[future]] = future.result()
            for ordinal, _, correlation, branch in armed:
                start = starts[ordinal]
                session_id = response_session_id(start)
                context_id = response_context_id(start)
                if context_id is None:
                    raise BenchmarkError("agent start omitted the child context_id")
                owned_worktree = discover_owned_worktree(start, root, branch)
                state["sessions"].append({"session_id": session_id, "context_id": context_id, "terminal": False})
                state["worktrees"].append({"path": str(owned_worktree), "owned": True, "branch": branch})
                save_json(artifact / "state.json", state)
                correctness = first_search_read(runner, plan, correlation, context_id)
                exported = runner.call(
                    f"export-{ordinal}", DEBUG_TOOL,
                    diagnostic_payload(plan, "export", correlation_id=correlation),
                )
                export_payload = find_object(exported, "sample")
                failures = validate_export(
                    export_payload, args.route, correctness,
                    expected_correlation=correlation,
                    expected_session=session_id,
                    expected_invocation=invocation,
                    expected_ordinal=ordinal,
                )
                status = terminalize(runner, session_id)
                state["sessions"][-1]["terminal"] = status in TERMINAL_STATES
                state["sessions"][-1]["status"] = status
                record = {
                    "schema_version": SCHEMA_VERSION, "plan_sha256": plan["plan_sha256"],
                    "artifact_id": artifact.name,
                    "process_state": args.process_state, "checkout_kind": args.checkout_kind,
                    "route": args.route, "width": args.width, "invocation": invocation,
                    "ordinal": ordinal, "warmup": warmup, "correlation_id": correlation,
                    "session_id": session_id,
                    "context_id": context_id, "correctness": correctness,
                    "valid": not failures, "invalid_reasons": failures, "diagnostic": export_payload,
                }
                sample_records.append(record)
                append_ndjson(artifact / "samples.ndjson", record)
                save_json(artifact / "state.json", state)
    except BaseException as error:
        operational_error = repr(error)
    finally:
        resources = runner.call(
            "memory-stop", DEBUG_TOOL,
            {"op": "large_workspace_memory", "action": "stop", "settle_seconds": 2},
            timeout=60, check=False,
        )
        save_json(artifact / "resources.json", resources, exclusive=True)
        state["memory_stopped"] = call_succeeded(resources) and find_value(resources, "running") is False
        restore_response = runner.call(
            "restore-route", DEBUG_TOOL,
            diagnostic_payload(plan, "restore_flags", control_id=control_id), check=False,
        )
        state["route_restored"] = call_succeeded(restore_response)
        reset_response = runner.call(
            "reset-scope", DEBUG_TOOL, diagnostic_payload(plan, "reset"), check=False
        )
        state["scope_reset"] = call_succeeded(reset_response) and isinstance(find_value(reset_response, "reset"), dict)
        try:
            require_benchmark_gate(runner)
            state["benchmark_gate_unchanged"] = True
        except BenchmarkError:
            state["benchmark_gate_unchanged"] = False
        cleanup: list[dict[str, Any]] = []
        for session in state["sessions"]:
            if not session.get("terminal"):
                session["status"] = terminalize(runner, session["session_id"])
                session["terminal"] = session["status"] in TERMINAL_STATES
            cleanup.append({
                "action": "terminalize_agent", "session_id": session["session_id"],
                "status": session.get("status"), "terminal": session.get("terminal") is True,
            })
        cleanup.extend([
            {
                "action": "stop_memory_sampler", "ok": state["memory_stopped"],
                "verified_stopped": state["memory_stopped"],
            },
            {"action": "restore_route", "ok": state["route_restored"]},
            {"action": "reset_diagnostics", "ok": state["scope_reset"]},
            {"action": "preserve_benchmark_setting", "ok": state["benchmark_gate_unchanged"]},
        ])
        for worktree in {item["path"]: item for item in state["worktrees"]}.values():
            cleanup.append(clean_owned_worktree(
                root, worktree["path"], all(item.get("terminal") for item in state["sessions"]),
                expected_branch=worktree.get("branch"),
            ))
        final_target_ok = False
        try:
            verify_disposable_target(runner, plan, require_only_planned_root=True)
            final_target_ok = True
        except BenchmarkError:
            pass
        cleanup.append({"action": "restore_workspace_roots", "ok": final_target_ok})
        save_json(artifact / "cleanup.json", cleanup, exclusive=True)
        save_json(artifact / "state.json", state)
    valid = [sample for sample in sample_records if sample["valid"] and not sample["warmup"]]
    cleanup_ok = validate_cleanup_evidence(
        cleanup, run_artifact=True, expected_agent_count=len(state["sessions"]),
        expected_worktree_count=len({item["path"] for item in state["worktrees"]}),
    )
    summary = {
        "schema_version": SCHEMA_VERSION,
        "status": "failed" if operational_error or not cleanup_ok else "completed",
        "artifact_id": artifact.name,
        "plan_sha256": plan["plan_sha256"], "artifact_directory": str(artifact),
        "process_state": args.process_state, "checkout_kind": args.checkout_kind,
        "route": args.route, "width": args.width, "invocation": args.invocation,
        "warmup_groups": args.warmups, "retained_groups": args.samples,
        "expected_sample_count": (args.warmups + args.samples) * args.width,
        "operational_error": operational_error,
        "sample_count": len(sample_records), "valid_retained_count": len(valid),
        "invalid_count": len([sample for sample in sample_records if not sample["valid"]]),
        "cleanup_complete": cleanup_ok,
    }
    save_json(artifact / "summary.json", summary, exclusive=True)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["status"] == "completed" else 1


def bounded_poll_search(
    runner: CLIRunner,
    context_id: str | None,
    marker: str,
    path: str,
    *,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
    present: bool,
    timeout: float = 30,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last_evidence: dict[str, Any] = {"ok": False, "error": "no structured response"}
    while time.monotonic() < deadline:
        response = runner.call(
            "watcher-poll", "file_search",
            {"pattern": marker, "regex": False, "mode": "content", "filter": {"paths": [path]},
             "max_results": 20, "context_id": context_id},
            timeout=60, check=False,
        )
        if present:
            last_evidence = structured_success_evidence(
                response, "file_search", expected_root_id=expected_root_id,
                expected_root_path=expected_root_path, expected_root_type=expected_root_type,
                expected_file_path=path, expected_file_type="file", expected_content=marker,
            )
        else:
            last_evidence = structured_empty_success_evidence(
                response, "file_search", expected_root_id=expected_root_id,
                expected_root_path=expected_root_path, expected_root_type=expected_root_type,
            )
        if last_evidence["ok"]:
            return last_evidence
        time.sleep(0.2)
    return last_evidence


def overlap(call: TimedCall, mutation: TimedCall) -> bool:
    return call.started_ns < mutation.finished_ns and call.finished_ns > mutation.started_ns


def call_succeeded(value: Any) -> bool:
    if isinstance(value, TimedCall):
        if value.returncode != 0:
            return False
        value = value.response
    if find_value(value, "_benchmark_cli_returncode") not in (None, 0):
        return False
    if find_value(value, "isError") is True:
        return False
    if find_value(value, "ok") is False:
        return False
    return True


def transcript_xml_from_log(value: Any) -> str:
    transcript = find_value(value, "transcript_xml")
    if not isinstance(transcript, str) or not transcript:
        raise BenchmarkError("agent log omitted transcript_xml")
    return transcript


def parse_agent_transcript_records(transcript_xml: str) -> dict[str, Any]:
    event_pattern = re.compile(
        r'<tool_call name="([^"]+)"(?:>(.*?)</tool_call>|/>)'
        r'|<tool_result name="([^"]+)"([^>]*?)(?:>(.*?)</tool_result>|/>)'
        r'|<assistant>(.*?)</assistant>',
        re.DOTALL,
    )
    calls: list[dict[str, Any]] = []
    results: list[dict[str, Any]] = []
    assistants: list[str] = []
    for ordinal, match in enumerate(event_pattern.finditer(transcript_xml), start=1):
        if match.group(1) is not None:
            tool = match.group(1).split("__")[-1]
            raw = match.group(2)
            if raw is None:
                arguments: Any = {}
            else:
                try:
                    arguments = json.loads(html.unescape(raw))
                except json.JSONDecodeError as error:
                    raise BenchmarkError(f"invalid structured {tool} transcript arguments") from error
            if not isinstance(arguments, dict):
                raise BenchmarkError(f"structured {tool} transcript arguments must be an object")
            calls.append({"ordinal": ordinal, "tool": tool, "arguments": arguments})
        elif match.group(3) is not None:
            tool = match.group(3).split("__")[-1]
            attributes = match.group(4) or ""
            status_match = re.search(r'\bstatus="([^"]+)"', attributes)
            raw_result = match.group(5)
            if raw_result is None or not raw_result.strip():
                raise BenchmarkError(f"structured {tool} transcript result omitted JSON payload")
            try:
                result = json.loads(html.unescape(raw_result))
            except json.JSONDecodeError as error:
                raise BenchmarkError(f"invalid structured {tool} transcript result") from error
            if not isinstance(result, dict):
                raise BenchmarkError(f"structured {tool} transcript result must be an object")
            results.append({
                "ordinal": ordinal, "tool": tool,
                "status": status_match.group(1) if status_match else result.get("status"),
                "result": result,
            })
        else:
            assistants.append(html.unescape(match.group(6) or "").strip())
    return {"calls": calls, "results": results, "assistants": assistants}


def verify_agent_file_tool_transcript(
    transcript_xml: str,
    *,
    expected_output: str,
    expected_marker: str,
    expected_file_path: str,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
) -> dict[str, Any]:
    records = parse_agent_transcript_records(transcript_xml)
    by_tool_calls = {
        tool: [item for item in records["calls"] if item["tool"] == tool]
        for tool in ("file_search", "read_file")
    }
    by_tool_results = {
        tool: [item for item in records["results"] if item["tool"] == tool]
        for tool in ("file_search", "read_file")
    }
    if any(len(by_tool_calls[tool]) != 1 or len(by_tool_results[tool]) != 1 for tool in by_tool_calls):
        raise BenchmarkError("child transcript requires exactly one file_search/read_file call and result")
    ordered = (
        by_tool_calls["file_search"][0]["ordinal"],
        by_tool_results["file_search"][0]["ordinal"],
        by_tool_calls["read_file"][0]["ordinal"],
        by_tool_results["read_file"][0]["ordinal"],
    )
    if ordered != tuple(sorted(ordered)) or any(
        by_tool_results[tool][0].get("status") not in {"ok", "completed", "ready", "success"}
        for tool in by_tool_results
    ):
        raise BenchmarkError("child transcript tool calls/results were unordered or unsuccessful")
    search_args = by_tool_calls["file_search"][0]["arguments"]
    read_args = by_tool_calls["read_file"][0]["arguments"]
    search_paths = ((search_args.get("filter") or {}).get("paths"))
    if (
        search_args.get("pattern") != expected_marker
        or search_args.get("regex") is not False
        or search_paths != [expected_file_path]
        or read_args.get("path") != expected_file_path
    ):
        raise BenchmarkError("child transcript file-tool arguments did not match the inherited-root request")
    search_result = require_structured_success(
        by_tool_results["file_search"][0]["result"], "file_search",
        expected_root_id=expected_root_id, expected_root_path=expected_root_path,
        expected_root_type=expected_root_type, expected_file_path=expected_file_path,
        expected_file_type="file", expected_content=expected_marker,
    )
    read_result = require_structured_success(
        by_tool_results["read_file"][0]["result"], "read_file",
        expected_root_id=expected_root_id, expected_root_path=expected_root_path,
        expected_root_type=expected_root_type, expected_file_path=expected_file_path,
        expected_file_type="file", expected_content=expected_marker,
    )
    if not records["assistants"] or records["assistants"][-1] != expected_output:
        raise BenchmarkError("child transcript final assistant output mismatch")
    return {
        "call_count": 2, "result_count": 2,
        "search_status": search_result["status"], "read_status": read_result["status"],
        "final_output": records["assistants"][-1],
    }


def poll_active_agent(
    runner: CLIRunner,
    session_id: str,
    expected_context_id: str,
    label: str,
) -> dict[str, Any]:
    call = runner.timed_call(
        label, "agent_run", {"op": "poll", "session_id": session_id}, check=False
    )
    response = call.response
    return {
        "label": label,
        "ok": (
            call_succeeded(response)
            and response_status(response) == "running"
            and response_context_id(response) == expected_context_id
        ),
        "status": response_status(response),
        "context_id": response_context_id(response),
        "started_ns": call.started_ns,
        "finished_ns": call.finished_ns,
    }


def wait_agent_success(
    runner: CLIRunner,
    session_id: str,
    *,
    expected_output: str,
    expected_marker: str,
    expected_file_path: str,
    expected_root_id: str,
    expected_root_path: str,
    expected_root_type: str,
) -> dict[str, Any]:
    waited = runner.call(
        f"wait-success-{session_id[:8]}", "agent_run",
        {"op": "wait", "session_id": session_id, "timeout": 180}, timeout=210, check=False,
    )
    log = runner.call(
        f"log-success-{session_id[:8]}", "agent_manage",
        {"op": "get_log", "session_id": session_id, "offset": 0, "limit": 1000},
        timeout=90, check=False,
    )
    status = response_status(waited)
    transcript_evidence: dict[str, Any] | None = None
    transcript_error: str | None = None
    try:
        transcript_evidence = verify_agent_file_tool_transcript(
            transcript_xml_from_log(log), expected_output=expected_output,
            expected_marker=expected_marker, expected_file_path=expected_file_path,
            expected_root_id=expected_root_id, expected_root_path=expected_root_path,
            expected_root_type=expected_root_type,
        )
    except BenchmarkError as error:
        transcript_error = str(error)
    return {
        "ok": (
            call_succeeded(waited)
            and call_succeeded(log)
            and status == "completed"
            and transcript_evidence is not None
        ),
        "status": status,
        "transcript_evidence": transcript_evidence,
        "transcript_error": transcript_error,
    }


def smoke_command(args: argparse.Namespace) -> int:
    if not args.confirm_live_debug_app or not args.confirm_dedicated_workspace:
        raise BenchmarkError("smoke requires both live-app and dedicated-workspace confirmations")
    plan = load_plan(Path(args.plan).expanduser().resolve(strict=True))
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"])
    artifact = make_artifact(Path(args.output_root), "correctness-smoke")
    runner = CLIRunner(cli, plan["scope"]["window_id"], root, artifact)
    save_json(artifact / "plan.json", plan, exclusive=True)
    verify_scope(runner, plan)
    verify_disposable_target(runner, plan, require_only_planned_root=True)
    results: dict[str, dict[str, Any]] = {}
    owned_dirs: list[Path] = []
    added_roots: list[Path] = []
    parent_session: str | None = None
    parent_context: str | None = None
    parent_worktree: Path | None = None
    parent_branch = safe_name(f"rpce-bench-smoke-{artifact.name}")[:120]
    linked_secondary: Path | None = None
    linked_parent: Path | None = None
    linked_file: Path | None = None
    smoke_cleanup: list[dict[str, Any]] = []
    detached_workspace_roots: set[Path] = set()
    relevant_agent_status: dict[str, str] = {}
    parent_activity: list[dict[str, Any]] = []
    child_session: str | None = None
    try:
        parent = runner.call(
            "active-parent-start", "agent_run",
            {
                "op": "start", "model_id": "explore", "detach": True,
                "message": (
                    "Run 200 sequential alternating file_search and read_file calls against "
                    f"{plan['dataset']['read_path']}. Do not edit or delegate. Then reply RPCE_ACTIVE_PARENT_OK."
                ),
                "session_name": "RPCE active-root smoke", "worktree_create": True,
                "worktree_branch": parent_branch,
                "worktree_base_ref": plan["dataset"]["base_ref"],
                "worktree_label": f"RPCE smoke {artifact.name}", "context_id": plan["scope"]["context_id"],
            }, timeout=180,
        )
        parent_session = response_session_id(parent)
        parent_context = response_context_id(parent)
        if parent_context is None:
            raise BenchmarkError("smoke parent start omitted context_id")
        parent_worktree = discover_owned_worktree(parent, root, parent_branch)
        parent_runtime = runner.call(
            "parent-root-identity", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        if not call_succeeded(parent_runtime):
            raise BenchmarkError("parent runtime root identity snapshot failed")
        parent_root_identity = runtime_root_identity(parent_runtime, str(parent_worktree))
        parent_activity.append(poll_active_agent(
            runner, parent_session, parent_context, "parent-poll-before"
        ))

        child = runner.call(
            "nested-child-start", "agent_run",
            {
                "op": "start", "model_id": "explore", "detach": True, "inherit_worktree": True,
                "message": (
                    "In the inherited worktree, call file_search exactly once for marker "
                    f"{plan['dataset']['search_marker']!r} scoped to {plan['dataset']['read_path']!r}, "
                    f"then call read_file exactly once for {plan['dataset']['read_path']!r}. "
                    "Require both calls to succeed and reply exactly RPCE_INHERITED_CHILD_OK."
                ),
                "session_name": "RPCE inherited child", "context_id": parent_context,
            }, timeout=180, check=False,
        )
        child_session = find_value(child, "session_id")
        child_parent = find_value(child, "parent_session_id")
        child_paths = response_worktree_paths(child)
        same_worktree = bool(
            parent_worktree
            and any(Path(path).resolve() == parent_worktree.resolve() for path in child_paths)
        )
        child_completion = (
            wait_agent_success(
                runner, child_session,
                expected_output="RPCE_INHERITED_CHILD_OK",
                expected_marker=plan["dataset"]["search_marker"],
                expected_file_path=plan["dataset"]["read_path"],
                expected_root_id=parent_root_identity["id"],
                expected_root_path=parent_root_identity["path"],
                expected_root_type=parent_root_identity["type"],
            )
            if isinstance(child_session, str)
            else {"ok": False, "status": "missing"}
        )
        if isinstance(child_session, str):
            relevant_agent_status[child_session] = str(child_completion["status"])
        nested_ok = (
            call_succeeded(child)
            and isinstance(child_session, str)
            and child_parent == parent_session
            and same_worktree
            and child_completion["ok"]
        )
        results["nested-inherited-worktree-agent"] = {
            "ok": nested_ok, "parent_session_id_matches": child_parent == parent_session,
            "same_worktree": same_worktree,
            "terminal_success": child_completion,
        }

        selected = runner.call(
            "selection-set", "manage_selection",
            {"op": "set", "paths": [plan["dataset"]["read_path"]], "mode": "full", "context_id": parent_context},
            check=False,
        )
        selected_get = runner.call(
            "selection-get", "manage_selection",
            {"op": "get", "view": "files", "context_id": parent_context}, check=False,
        )
        structure = runner.call(
            "structure-selected", "get_code_structure",
            {"scope": "selected", "context_id": parent_context}, check=False,
        )
        explicit_structure = runner.call(
            "structure-explicit", "get_code_structure",
            {"paths": [plan["dataset"]["read_path"]], "context_id": parent_context}, check=False,
        )
        selected_evidence = structured_success_evidence(
            selected_get, "manage_selection",
            expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"],
            expected_file_type="file",
        )
        results["selection-exact-root"] = {
            "ok": call_succeeded(selected) and selected_evidence["ok"],
            "structured_evidence": selected_evidence,
        }
        structure_selected = structured_success_evidence(
            structure, "get_code_structure",
            expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"],
            expected_file_type=plan["dataset"]["code_file_type"],
            expected_content=plan["dataset"]["read_marker"],
        )
        structure_explicit = structured_success_evidence(
            explicit_structure, "get_code_structure",
            expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"],
            expected_file_type=plan["dataset"]["code_file_type"],
            expected_content=plan["dataset"]["read_marker"],
        )
        results["code-structure-exact-root"] = {
            "ok": structure_selected["ok"] and structure_explicit["ok"],
            "selected": structure_selected,
            "explicit": structure_explicit,
        }

        non_git = Path(tempfile.mkdtemp(prefix="rpce-startup-nongit-"))
        owned_dirs.append(non_git)
        non_git_marker = f"RPCE_NON_GIT_{uuid.uuid4().hex}"
        (non_git / "NonGit.swift").write_text(f"struct {non_git_marker} {{}}\n", encoding="utf-8")
        add_non_git = runner.timed_call(
            "add-non-git", "manage_workspaces",
            {"action": "add_folder", "workspace": plan["scope"]["workspace_id"],
             "folder_path": str(non_git), "window_id": plan["scope"]["window_id"]},
        )
        added_roots.append(non_git)
        non_git_runtime = runner.call(
            "non-git-root-identity", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        if not call_succeeded(non_git_runtime):
            raise BenchmarkError("non-Git runtime root identity snapshot failed")
        non_git_root_identity = runtime_root_identity(non_git_runtime, str(non_git))
        non_git_search = runner.call(
            "non-git-search", "file_search",
            {"pattern": non_git_marker, "regex": False, "filter": {"paths": [str(non_git)]}, "context_id": parent_context},
            check=False,
        )
        non_git_read = runner.call(
            "non-git-read", "read_file", {"path": str(non_git / "NonGit.swift"), "context_id": parent_context}, check=False,
        )
        work_before = runner.call(
            "non-git-work-before", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        non_git_structure = runner.call(
            "non-git-structure", "get_code_structure", {"paths": [str(non_git / "NonGit.swift")], "context_id": parent_context},
            check=False,
        )
        main_structure_after_non_git = runner.call(
            "main-structure-after-non-git", "get_code_structure",
            {"scope": "paths", "paths": [plan["dataset"]["read_path"]],
             "context_id": parent_context}, check=False,
        )
        work_after = runner.call(
            "non-git-work-after", DEBUG_TOOL,
            {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
             "recent_publication_limit": 0, "root_limit": 256}, check=False,
        )
        non_git_work = [
            record for record in new_records(git_work_records(work_before), git_work_records(work_after))
            if record.get("operation") == "get_code_structure"
        ]
        zero_git = len(non_git_work) == 1 and non_git_work[0].get("command_count") == 0
        non_git_search_evidence = structured_success_evidence(
            non_git_search, "file_search",
            expected_root_id=non_git_root_identity["id"],
            expected_root_path=non_git_root_identity["path"],
            expected_root_type=non_git_root_identity["type"],
            expected_file_path=str(non_git / "NonGit.swift"), expected_file_type="file",
            expected_content=non_git_marker,
        )
        non_git_read_evidence = structured_success_evidence(
            non_git_read, "read_file",
            expected_root_id=non_git_root_identity["id"],
            expected_root_path=non_git_root_identity["path"],
            expected_root_type=non_git_root_identity["type"],
            expected_file_path=str(non_git / "NonGit.swift"), expected_file_type="file",
            expected_content=non_git_marker,
        )
        non_git_structure_evidence = structured_removed_evidence(
            non_git_structure, "get_code_structure",
            expected_root_id=non_git_root_identity["id"],
            expected_root_path=non_git_root_identity["path"],
            expected_root_type=non_git_root_identity["type"],
        )
        results["non-git-root"] = {
            "ok": (
                non_git_search_evidence["ok"]
                and non_git_read_evidence["ok"]
                and non_git_structure_evidence["ok"]
                and zero_git
            ),
            "search": non_git_search_evidence,
            "read": non_git_read_evidence,
            "structure": non_git_structure_evidence,
            "git_work_record_count": len(non_git_work),
            "git_command_count": non_git_work[0].get("command_count") if len(non_git_work) == 1 else None,
        }
        cross = runner.call(
            "cross-root-negative", "file_search",
            {"pattern": non_git_marker, "regex": False, "filter": {"paths": [plan["scope"]["root_path"]],
             "exclude": [str(non_git)]}, "context_id": parent_context}, check=False,
        )
        cross_search_evidence = structured_empty_success_evidence(
            cross, "file_search", expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
        )
        cross_structure_evidence = structured_success_evidence(
            main_structure_after_non_git, "get_code_structure",
            expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"],
            expected_file_type=plan["dataset"]["code_file_type"],
            expected_content=plan["dataset"]["read_marker"],
        )
        results["cross-root-negative"] = {
            "ok": cross_search_evidence["ok"] and cross_structure_evidence["ok"],
            "search": cross_search_evidence,
            "structure": cross_structure_evidence,
        }

        ordinary = Path(tempfile.mkdtemp(prefix="rpce-startup-ordinary-"))
        owned_dirs.append(ordinary)
        ordinary_marker = f"RPCE_ORDINARY_{uuid.uuid4().hex}"
        ordinary_file = ordinary / "Ordinary.swift"
        ordinary_file.write_text(f"struct {ordinary_marker} {{}}\n", encoding="utf-8")
        linked_parent = Path(tempfile.mkdtemp(prefix="rpce-startup-linked-parent-"))
        linked_secondary = linked_parent / "worktree"
        run_local(["git", "worktree", "add", "--detach", str(linked_secondary), plan["dataset"]["base_ref"]], root)
        linked_marker = f"RPCE_LINKED_{uuid.uuid4().hex}"
        linked_file = linked_secondary / f"{linked_marker}.swift"
        linked_file.write_text(f"struct {linked_marker} {{}}\n", encoding="utf-8")

        def in_flight_calls(label: str, marker: str, file_path: str) -> dict[str, TimedCall]:
            calls = {
                "search": ("file_search", {"pattern": marker, "regex": False, "mode": "content", "filter": {"paths": [file_path]}, "max_results": 2000, "context_id": parent_context}),
                "read": ("read_file", {"path": file_path, "start_line": 1, "limit": 1000, "context_id": parent_context}),
                "selection": ("manage_selection", {"op": "get", "view": "files", "context_id": parent_context}),
                "structure": ("get_code_structure", {
                    "scope": "paths", "paths": [file_path],
                    "limits": {"max_files": 100, "max_edges": 200, "max_codemap_tokens": 6000},
                    "context_id": parent_context,
                }),
            }
            with ThreadPoolExecutor(max_workers=4) as pool:
                futures = {
                    key: pool.submit(runner.timed_call, f"{label}-{key}", tool, payload, check=False)
                    for key, (tool, payload) in calls.items()
                }
                return {key: future.result() for key, future in futures.items()}

        for kind, secondary, secondary_file, secondary_marker in (
            ("ordinary", ordinary, ordinary_file, ordinary_marker),
            ("worktree", linked_secondary, linked_file, linked_marker),
        ):
            parent_activity.append(poll_active_agent(
                runner, parent_session, parent_context, f"parent-{kind}-before-add"
            ))
            with ThreadPoolExecutor(max_workers=2) as pool:
                calls_future = pool.submit(
                    in_flight_calls, f"{kind}-add-inflight",
                    plan["dataset"]["search_marker"], plan["dataset"]["read_path"],
                )
                mutation_future = pool.submit(
                    runner.timed_call, f"add-{kind}-root", "manage_workspaces",
                    {"action": "add_folder", "workspace": plan["scope"]["workspace_id"],
                     "folder_path": str(secondary), "window_id": plan["scope"]["window_id"]},
                )
                during_add = poll_active_agent(
                    runner, parent_session, parent_context, f"parent-{kind}-during-add"
                )
                calls, mutation = calls_future.result(), mutation_future.result()
            during_add["overlapped_mutation"] = (
                during_add["started_ns"] < mutation.finished_ns
                and during_add["finished_ns"] > mutation.started_ns
            )
            parent_activity.append(during_add)
            added_roots.append(secondary)
            parent_activity.append(poll_active_agent(
                runner, parent_session, parent_context, f"parent-{kind}-after-add"
            ))
            overlapped_add = [key for key, call in calls.items() if overlap(call, mutation) and call_succeeded(call)]
            overlap_add = call_succeeded(mutation) and bool(overlapped_add)
            inventory_after_add = runner.call(
                f"inventory-{kind}-after-add", "manage_workspaces",
                {"action": "list", "include_hidden": True}, check=False,
            )
            added_inventory_paths = (
                workspace_root_paths(workspace_inventory_record(inventory_after_add, plan["scope"]["workspace_id"]))
                if call_succeeded(inventory_after_add) else []
            )
            secondary_runtime = runner.call(
                f"{kind}-root-identity", DEBUG_TOOL,
                {"op": "mcp_read_search_runtime_snapshot", "window_id": plan["scope"]["window_id"],
                 "recent_publication_limit": 0, "root_limit": 256}, check=False,
            )
            if not call_succeeded(secondary_runtime):
                raise BenchmarkError(f"{kind} runtime root identity snapshot failed")
            secondary_root_identity = runtime_root_identity(secondary_runtime, str(secondary))
            added_search = runner.call(
                f"{kind}-added-search", "file_search",
                {"pattern": secondary_marker, "regex": False, "mode": "content",
                 "filter": {"paths": [str(secondary_file)]}, "context_id": parent_context}, check=False,
            )
            added_read = runner.call(
                f"{kind}-added-read", "read_file",
                {"path": str(secondary_file), "start_line": 1, "limit": 40,
                 "context_id": parent_context}, check=False,
            )
            selection_add = runner.call(
                f"{kind}-selection-add", "manage_selection",
                {"op": "add", "paths": [str(secondary_file)], "mode": "full",
                 "context_id": parent_context}, check=False,
            )
            selection_with_root = runner.call(
                f"{kind}-selection-after-add", "manage_selection",
                {"op": "get", "view": "files", "context_id": parent_context}, check=False,
            )
            added_structure = runner.call(
                f"{kind}-structure-after-add", "get_code_structure",
                {"scope": "paths", "paths": [str(secondary_file)],
                 "context_id": parent_context}, check=False,
            )
            added_search_evidence = structured_success_evidence(
                added_search, "file_search", expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file), expected_file_type="file",
                expected_content=secondary_marker,
            )
            added_read_evidence = structured_success_evidence(
                added_read, "read_file", expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file), expected_file_type="file",
                expected_content=secondary_marker,
            )
            added_selection_evidence = structured_success_evidence(
                selection_with_root, "manage_selection",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file), expected_file_type="file",
                require_only_file=False,
            )
            added_structure_evidence = structured_success_evidence(
                added_structure, "get_code_structure",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
                expected_file_path=str(secondary_file),
                expected_file_type=plan["dataset"]["code_file_type"],
                expected_content=secondary_marker,
            )
            added_usable = (
                str(secondary.resolve()) in added_inventory_paths
                and added_search_evidence["ok"] and added_read_evidence["ok"]
                and call_succeeded(selection_add) and added_selection_evidence["ok"]
                and added_structure_evidence["ok"]
            )
            results[f"secondary-{kind}-root-in-flight"] = {
                "ok": overlap_add, "add_overlapped_calls": overlapped_add,
            }
            results[f"secondary-{kind}-root-idle"] = {
                "ok": call_succeeded(mutation) and added_usable,
                "visible_and_usable_after_add": added_usable,
                "search": added_search_evidence, "read": added_read_evidence,
                "selection": added_selection_evidence, "structure": added_structure_evidence,
            }

            parent_activity.append(poll_active_agent(
                runner, parent_session, parent_context, f"parent-{kind}-before-remove"
            ))
            with ThreadPoolExecutor(max_workers=2) as pool:
                calls_future = pool.submit(
                    in_flight_calls, f"{kind}-remove-inflight", secondary_marker, str(secondary_file)
                )
                mutation_future = pool.submit(
                    runner.timed_call, f"remove-{kind}-root", "manage_workspaces",
                    {"action": "remove_folder", "workspace": plan["scope"]["workspace_id"],
                     "folder_path": str(secondary), "window_id": plan["scope"]["window_id"]},
                )
                during_remove = poll_active_agent(
                    runner, parent_session, parent_context, f"parent-{kind}-during-remove"
                )
                calls, mutation = calls_future.result(), mutation_future.result()
            during_remove["overlapped_mutation"] = (
                during_remove["started_ns"] < mutation.finished_ns
                and during_remove["finished_ns"] > mutation.started_ns
            )
            parent_activity.append(during_remove)
            if call_succeeded(mutation):
                added_roots.remove(secondary)
                detached_workspace_roots.add(secondary.resolve())
            if call_succeeded(mutation):
                smoke_cleanup.append({
                    "action": "remove_workspace_root", "path": str(secondary), "ok": True,
                })
            parent_activity.append(poll_active_agent(
                runner, parent_session, parent_context, f"parent-{kind}-after-remove"
            ))
            remove_overlapped = [key for key, call in calls.items() if overlap(call, mutation) and call_succeeded(call)]
            inventory_after_remove = runner.call(
                f"inventory-{kind}-after-remove", "manage_workspaces",
                {"action": "list", "include_hidden": True}, check=False,
            )
            removed_inventory_paths = (
                workspace_root_paths(workspace_inventory_record(inventory_after_remove, plan["scope"]["workspace_id"]))
                if call_succeeded(inventory_after_remove) else []
            )
            removed_search = runner.call(
                f"{kind}-removed-search", "file_search",
                {"pattern": secondary_marker, "regex": False, "mode": "content",
                 "filter": {"paths": [str(secondary_file)]}, "context_id": parent_context}, check=False,
            )
            removed_read = runner.call(
                f"{kind}-removed-read", "read_file",
                {"path": str(secondary_file), "start_line": 1, "limit": 40,
                 "context_id": parent_context}, check=False,
            )
            selection_after_remove = runner.call(
                f"{kind}-selection-after-remove", "manage_selection",
                {"op": "get", "view": "files", "context_id": parent_context}, check=False,
            )
            structure_after_remove = runner.call(
                f"{kind}-structure-after-remove", "get_code_structure",
                {"scope": "paths", "paths": [str(secondary_file)],
                 "context_id": parent_context}, check=False,
            )
            removed_search_evidence = structured_removed_evidence(
                removed_search, "file_search",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
            )
            removed_read_evidence = structured_removed_evidence(
                removed_read, "read_file",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
            )
            removed_structure_evidence = structured_removed_evidence(
                structure_after_remove, "get_code_structure",
                expected_root_id=secondary_root_identity["id"],
                expected_root_path=secondary_root_identity["path"],
                expected_root_type=secondary_root_identity["type"],
            )
            selection_after_remove_evidence = structured_success_evidence(
                selection_after_remove, "manage_selection",
                expected_root_id=parent_root_identity["id"],
                expected_root_path=parent_root_identity["path"],
                expected_root_type=parent_root_identity["type"],
                expected_file_path=plan["dataset"]["read_path"],
                expected_file_type="file",
            )
            removed_revoked = (
                str(secondary.resolve()) not in removed_inventory_paths
                and removed_search_evidence["ok"]
                and removed_read_evidence["ok"]
                and removed_structure_evidence["ok"]
                and selection_after_remove_evidence["ok"]
            )
            results[f"secondary-{kind}-root-in-flight"]["remove_overlapped_calls"] = remove_overlapped
            results[f"secondary-{kind}-root-in-flight"]["ok"] = (
                results[f"secondary-{kind}-root-in-flight"]["ok"]
                and call_succeeded(mutation) and bool(remove_overlapped) and removed_revoked
            )
            results[f"secondary-{kind}-root-in-flight"]["removed_state_revoked"] = removed_revoked
            results[f"secondary-{kind}-root-in-flight"]["removed_search"] = removed_search_evidence
            results[f"secondary-{kind}-root-in-flight"]["removed_read"] = removed_read_evidence
            results[f"secondary-{kind}-root-in-flight"]["removed_structure"] = removed_structure_evidence
            results[f"secondary-{kind}-root-in-flight"]["selection_after_remove"] = selection_after_remove_evidence
            results[f"secondary-{kind}-root-idle"]["ok"] = (
                results[f"secondary-{kind}-root-idle"]["ok"] and removed_revoked
            )
            results[f"secondary-{kind}-root-idle"]["removed_state_revoked"] = removed_revoked

        if parent_worktree:
            relative_dir = ".rpce-benchmark"
            old_relative = f"{relative_dir}/{artifact.name}.swift"
            new_relative = f"{relative_dir}/{artifact.name}-renamed.swift"
            marker_v1 = f"RPCE_WATCHER_{uuid.uuid4().hex}_V1"
            marker_v2 = marker_v1.replace("_V1", "_V2")
            created = runner.call(
                "watcher-create", "file_actions",
                {"action": "create", "path": str(parent_worktree / old_relative), "content": f"struct {marker_v1} {{}}\n", "context_id": parent_context},
                check=False,
            )
            watcher_root = {
                "expected_root_id": parent_root_identity["id"],
                "expected_root_path": parent_root_identity["path"],
                "expected_root_type": parent_root_identity["type"],
            }
            create_visible = bounded_poll_search(
                runner, parent_context, marker_v1, old_relative, present=True, **watcher_root
            )
            edited = runner.call(
                "watcher-edit", "apply_edits",
                {"path": old_relative, "search": marker_v1, "replace": marker_v2, "context_id": parent_context}, check=False,
            )
            edit_visible = bounded_poll_search(
                runner, parent_context, marker_v2, old_relative, present=True, **watcher_root
            )
            moved = runner.call(
                "watcher-rename", "file_actions",
                {"action": "move", "path": str(parent_worktree / old_relative),
                 "new_path": str(parent_worktree / new_relative), "context_id": parent_context}, check=False,
            )
            rename_visible = bounded_poll_search(
                runner, parent_context, marker_v2, new_relative, present=True, **watcher_root
            )
            old_absent = bounded_poll_search(
                runner, parent_context, marker_v2, old_relative, present=False, **watcher_root
            )
            deleted = runner.call(
                "watcher-delete", "file_actions",
                {"action": "delete", "path": str(parent_worktree / new_relative), "context_id": parent_context}, check=False,
            )
            delete_absent = bounded_poll_search(
                runner, parent_context, marker_v2, new_relative, present=False, **watcher_root
            )
            results["watcher-create-edit-rename-delete"] = {
                "ok": all((
                    call_succeeded(created), call_succeeded(edited), call_succeeded(moved), call_succeeded(deleted),
                    create_visible["ok"], edit_visible["ok"], rename_visible["ok"],
                    old_absent["ok"], delete_absent["ok"],
                )),
                "create_visible": create_visible, "edit_visible": edit_visible,
                "rename_visible": rename_visible, "old_absent": old_absent, "delete_absent": delete_absent,
                "tool_calls_succeeded": all(call_succeeded(item) for item in (created, edited, moved, deleted)),
            }

        parent_activity.append(poll_active_agent(
            runner, parent_session, parent_context, "parent-poll-after"
        ))
        surviving_search = runner.call(
            "surviving-root-search", "file_search",
            {"pattern": plan["dataset"]["search_marker"], "regex": False,
             "filter": {"paths": [plan["dataset"]["read_path"]]}, "context_id": parent_context}, check=False,
        )
        surviving_read = runner.call(
            "surviving-root-read", "read_file",
            {"path": plan["dataset"]["read_path"], "start_line": 1, "limit": 80,
            "context_id": parent_context}, check=False,
        )
        surviving_search_evidence = structured_success_evidence(
            surviving_search, "file_search", expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"], expected_file_type="file",
            expected_content=plan["dataset"]["search_marker"],
        )
        surviving_read_evidence = structured_success_evidence(
            surviving_read, "read_file", expected_root_id=parent_root_identity["id"],
            expected_root_path=parent_root_identity["path"],
            expected_root_type=parent_root_identity["type"],
            expected_file_path=plan["dataset"]["read_path"], expected_file_type="file",
            expected_content=plan["dataset"]["read_marker"],
        )
        results["active-agent-tab-binding"] = {
            "ok": (
                bool(parent_activity)
                and all(item["ok"] for item in parent_activity)
                and all(
                    item.get("overlapped_mutation") is True
                    for item in parent_activity
                    if "during-" in str(item.get("label", ""))
                )
                and surviving_search_evidence["ok"]
                and surviving_read_evidence["ok"]
            ),
            "activity_checks": parent_activity,
            "context_id_unchanged": all(
                item.get("context_id") == parent_context for item in parent_activity
            ),
            "surviving_root_usable": (
                surviving_search_evidence["ok"] and surviving_read_evidence["ok"]
            ),
            "surviving_search": surviving_search_evidence,
            "surviving_read": surviving_read_evidence,
        }
    finally:
        for path in reversed(added_roots):
            removal_response = runner.call(
                f"cleanup-remove-{safe_name(path.name)}", "manage_workspaces",
                {"action": "remove_folder", "workspace": plan["scope"]["workspace_id"],
                 "folder_path": str(path), "window_id": plan["scope"]["window_id"]}, check=False,
            )
            smoke_cleanup.append({"action": "remove_workspace_root", "path": str(path), "ok": call_succeeded(removal_response)})
            if call_succeeded(removal_response):
                detached_workspace_roots.add(path.resolve())
        if child_session:
            child_status = relevant_agent_status.get(child_session)
            if child_status not in TERMINAL_STATES:
                child_status = terminalize(runner, child_session)
                relevant_agent_status[child_session] = child_status
            smoke_cleanup.append({
                "action": "terminalize_child", "session_id": child_session,
                "status": child_status, "terminal": child_status in TERMINAL_STATES,
            })
        if parent_session:
            parent_status = terminalize(runner, parent_session)
            relevant_agent_status[parent_session] = parent_status
            smoke_cleanup.append({
                "action": "terminalize_parent", "session_id": parent_session,
                "status": parent_status, "terminal": parent_status in TERMINAL_STATES,
            })
        all_relevant_terminal = bool(relevant_agent_status) and all(
            status in TERMINAL_STATES for status in relevant_agent_status.values()
        )
        if parent_worktree:
            smoke_cleanup.append(clean_owned_worktree(
                root, str(parent_worktree), all_relevant_terminal, expected_branch=parent_branch
            ))
        if linked_secondary and linked_secondary.resolve() in detached_workspace_roots:
            if linked_file and linked_file.exists():
                linked_file.unlink()
            smoke_cleanup.append(clean_owned_worktree(
                root, str(linked_secondary), all_relevant_terminal,
                expected_path=str(linked_secondary)
            ))
        if linked_parent:
            try:
                linked_parent.rmdir()
            except OSError:
                pass
        for path in reversed(owned_dirs):
            if path.resolve() in detached_workspace_roots:
                shutil.rmtree(path, ignore_errors=True)
        final_target_ok = False
        try:
            verify_disposable_target(runner, plan, require_only_planned_root=True)
            final_target_ok = True
        except BenchmarkError:
            pass
        smoke_cleanup.append({
            "action": "restore_workspace_roots", "ok": final_target_ok,
        })
        smoke_cleanup.extend([
            {"action": "route_control_unchanged", "ok": True},
            {"action": "benchmark_setting_unchanged", "ok": True},
            {"action": "diagnostics_reset_not_required", "ok": True},
        ])
    save_json(artifact / "cleanup.json", smoke_cleanup, exclusive=True)
    for scenario in CORRECTNESS_SCENARIOS:
        results.setdefault(scenario, {"ok": False, "reason": "not_exercised"})
    smoke_cleanup_ok = all(
        item.get("terminal") is True
        or item.get("ok") is True
        or item.get("removed") is True
        or item.get("reason") == "already_absent"
        for item in smoke_cleanup
    )
    summary = {
        "schema_version": SCHEMA_VERSION,
        "status": "completed" if all(item.get("ok") for item in results.values()) and smoke_cleanup_ok else "failed",
        "artifact_id": artifact.name,
        "plan_sha256": plan["plan_sha256"], "artifact_directory": str(artifact),
        "cleanup_complete": smoke_cleanup_ok, "results": results,
    }
    save_json(artifact / "summary.json", summary, exclusive=True)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if summary["status"] == "completed" else 1


def gate_ratio(control: float | None, candidate: float | None) -> float | None:
    if control in (None, 0) or candidate is None:
        return None
    return (control - candidate) / control


def diagnostic_number(
    item: dict[str, Any],
    section: str,
    field: str,
    subsection: str | None = None,
) -> float | None:
    value = find_value(item.get("diagnostic"), section)
    if not isinstance(value, dict):
        return None
    if subsection is not None:
        value = value.get(subsection)
        if not isinstance(value, dict):
            return None
    number = value.get(field)
    return float(number) if finite_number(number) else None


def absolute_memory_regression(control: Iterable[float], candidate: Iterable[float]) -> float | None:
    control_values = [float(value) for value in control]
    candidate_values = [float(value) for value in candidate]
    if not control_values or not candidate_values:
        return None
    if not all(math.isfinite(value) and value > 0 for value in control_values + candidate_values):
        return None
    baseline = statistics.median(control_values)
    if baseline <= 0:
        return None
    return statistics.median(candidate_values) / baseline - 1.0


def cleanup_entry_succeeded(item: dict[str, Any]) -> bool:
    return (
        item.get("terminal") is True
        or item.get("ok") is True
        or item.get("removed") is True
        or item.get("reason") == "already_absent"
    )


def validate_cleanup_evidence(
    entries: list[dict[str, Any]],
    *,
    run_artifact: bool,
    expected_agent_count: int,
    expected_worktree_count: int,
) -> bool:
    if not entries or not all(cleanup_entry_succeeded(item) for item in entries):
        return False
    by_action: dict[str, list[dict[str, Any]]] = {}
    for item in entries:
        action = item.get("action")
        if isinstance(action, str):
            by_action.setdefault(action, []).append(item)
    if run_artifact and len(by_action.get("terminalize_agent", [])) != expected_agent_count:
        return False
    if len(by_action.get("remove_worktree", [])) != expected_worktree_count:
        return False
    required = (
        {
            "stop_memory_sampler", "restore_route", "reset_diagnostics",
            "preserve_benchmark_setting", "restore_workspace_roots",
        }
        if run_artifact else
        {
            "terminalize_child", "terminalize_parent", "restore_workspace_roots",
            "route_control_unchanged", "benchmark_setting_unchanged",
            "diagnostics_reset_not_required",
        }
    )
    if not run_artifact and len(by_action.get("remove_workspace_root", [])) < 3:
        return False
    if run_artifact and (
        len(by_action.get("stop_memory_sampler", [])) != 1
        or not all(
        item.get("ok") is True and item.get("verified_stopped") is True
        for item in by_action.get("stop_memory_sampler", [])
        )
    ):
        return False
    return required <= set(by_action)


def stop_and_verify_memory_sampler(runner: CLIRunner) -> dict[str, Any]:
    stopped = runner.call(
        "cleanup-memory-stop", DEBUG_TOOL,
        {"op": "large_workspace_memory", "action": "stop", "settle_seconds": 2},
        timeout=60, check=False,
    )
    verified = runner.call(
        "cleanup-memory-verify", DEBUG_TOOL,
        {"op": "large_workspace_memory", "action": "current"},
        timeout=60, check=False,
    )
    stop_running = find_value(stopped, "running")
    verify_running = find_value(verified, "running")
    ok = (
        call_succeeded(stopped) and stop_running is False
        and call_succeeded(verified) and verify_running is False
    )
    return {
        "action": "stop_memory_sampler", "ok": ok, "verified_stopped": ok,
        "stop_running": stop_running, "verify_running": verify_running,
    }


def render_scoreboard(summary: dict[str, Any]) -> str:
    lines = [
        f"## Worktree startup live benchmark — {summary['aggregate_id']}", "",
        f"- Plan SHA-256: `{summary['plan_sha256']}`",
        f"- Decision: **{summary['decision']}**",
        f"- Generated: `{summary['created_at']}`", "",
        "| cohort | metric | N | p50 µs | p95 µs | CV |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for key, cohort in sorted(summary["cohorts"].items()):
        for metric, values in cohort["metrics"].items():
            lines.append(
                f"| `{key}` | `{metric}` | {values['count']} | {values['p50']} | {values['p95']} | {values['cv']} |"
            )
    lines.extend([
        "", "### Route and work attribution", "",
        "| cohort | routes | fallbacks | Git commands p50 | Git µs p50 | FS ops p50 | FS µs p50 | CPU ms | peak physical Δ MB | retained physical Δ MB |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ])
    for key, cohort in sorted(summary["cohorts"].items()):
        resources = cohort.get("resources") or []
        cpu = [item.get("session_cpu_ms") for item in resources if isinstance(item.get("session_cpu_ms"), (int, float))]
        peak = [item.get("peak_physical_footprint_delta_mb") for item in resources if isinstance(item.get("peak_physical_footprint_delta_mb"), (int, float))]
        retained = [item.get("retained_physical_footprint_delta_mb") for item in resources if isinstance(item.get("retained_physical_footprint_delta_mb"), (int, float))]
        lines.append(
            f"| `{key}` | `{cohort.get('route_counts', {})}` | `{cohort.get('fallback_counts', {})}` | "
            f"{cohort['git_command_count']['p50']} | {cohort['git_duration_us']['p50']} | "
            f"{cohort['filesystem_operation_count']['p50']} | {cohort['filesystem_duration_us']['p50']} | "
            f"{statistics.median(cpu) if cpu else None} | {statistics.median(peak) if peak else None} | "
            f"{statistics.median(retained) if retained else None} |"
        )
    lines.extend(["", "### Gates", "", "| gate | result |", "|---|---|"])
    for gate, value in summary["gates"].items():
        lines.append(f"| {gate} | `{value}` |")
    lines.extend(["", "### Evidence", ""])
    lines.append(f"- Correctness results: `{summary['correctness']}`")
    lines.append(f"- Invalid attempted samples: `{summary['invalid_attempted_samples']}`")
    lines.append(f"- Invalid retained samples: `{summary['invalid_retained_samples']}`")
    lines.append(f"- Artifact directories: `{', '.join(summary['artifacts'])}`")
    return "\n".join(lines) + "\n"


def aggregate_command(args: argparse.Namespace) -> int:
    plan = load_plan(Path(args.plan).expanduser().resolve(strict=True))
    samples: list[dict[str, Any]] = []
    correctness: list[dict[str, Any]] = []
    resource_records: dict[str, list[dict[str, Any]]] = {}
    teardown_results: list[bool] = []
    artifacts: list[str] = []
    artifact_paths: set[Path] = set()
    artifact_ids: set[str] = set()
    cohort_invocations: set[tuple[str, str, str, int, int]] = set()
    sample_identities: set[tuple[str, int, str, str, str, int, int, str, str]] = set()
    correlation_ids: set[str] = set()
    session_ids: set[str] = set()
    ordinal_identity_map: dict[tuple[str, int, int], tuple[str, str]] = {}
    for raw in args.artifact:
        artifact = Path(raw).expanduser().resolve(strict=True)
        register_unique(artifact, artifact_paths, "artifact path")
        artifacts.append(str(artifact))
        summary_file = artifact / "summary.json"
        if not summary_file.exists():
            raise BenchmarkError(f"artifact omitted summary.json: {artifact}")
        item = json.loads(summary_file.read_text(encoding="utf-8"))
        if item.get("plan_sha256") != plan["plan_sha256"]:
            raise BenchmarkError(f"artifact summary does not match plan: {artifact}")
        artifact_id = item.get("artifact_id")
        if artifact_id != artifact.name:
            raise BenchmarkError(f"mismatched artifact identity: {artifact}")
        register_unique(artifact_id, artifact_ids, "artifact identity")
        run_fields = ("process_state", "checkout_kind", "route", "width", "invocation")
        is_run = all(item.get(field) is not None for field in run_fields)
        expected_sample_count = 0
        if is_run:
            cohort_invocation = (
                str(item["process_state"]), str(item["checkout_kind"]), str(item["route"]),
                int(item["width"]), int(item["invocation"]),
            )
            register_unique(cohort_invocation, cohort_invocations, "cohort invocation")
            expected_sample_count = int(item.get("expected_sample_count", -1))
            expected_from_groups = (
                int(item.get("warmup_groups", -1)) + int(item.get("retained_groups", -1))
            ) * int(item["width"])
            if expected_sample_count <= 0 or expected_sample_count != expected_from_groups:
                raise BenchmarkError(f"invalid expected sample accounting in {artifact}")
            sample_file = artifact / "samples.ndjson"
            if not sample_file.exists():
                raise BenchmarkError(f"run artifact omitted samples.ndjson: {artifact}")
            artifact_samples: list[dict[str, Any]] = []
            for line in sample_file.read_text(encoding="utf-8").splitlines():
                sample = json.loads(line)
                if sample.get("schema_version") != SCHEMA_VERSION or sample.get("plan_sha256") != plan["plan_sha256"]:
                    raise BenchmarkError(f"sample schema/plan mismatch in {artifact}")
                for field in ("invocation", "width", "ordinal"):
                    if not positive_integer(sample.get(field)):
                        raise BenchmarkError(f"sample {field} must be a positive integer in {artifact}")
                if not isinstance(sample.get("warmup"), bool) or not isinstance(sample.get("valid"), bool):
                    raise BenchmarkError(f"sample warmup/valid flags must be booleans in {artifact}")
                if not isinstance(sample.get("correlation_id"), str) or not isinstance(sample.get("session_id"), str):
                    raise BenchmarkError(f"sample correlation/session IDs must be strings in {artifact}")
                record_correlation = validate_uuid(
                    sample["correlation_id"], "sample record correlation_id"
                )
                record_session = validate_uuid(
                    sample["session_id"], "sample session_id"
                )
                identity = (
                    str(sample.get("artifact_id")), sample["invocation"],
                    str(sample.get("process_state")), str(sample.get("checkout_kind")),
                    str(sample.get("route")), sample["width"],
                    sample["ordinal"], record_correlation, record_session,
                )
                expected_prefix = (
                    artifact_id, int(item["invocation"]), str(item["process_state"]),
                    str(item["checkout_kind"]), str(item["route"]), int(item["width"]),
                )
                if identity[:6] != expected_prefix:
                    raise BenchmarkError(f"mixed sample identity: {identity}")
                diagnostic_sample = find_value(sample.get("diagnostic"), "sample")
                if not isinstance(diagnostic_sample, dict):
                    raise BenchmarkError(f"sample omitted diagnostic payload in {artifact}")
                correlation_id = validate_uuid(
                    str(diagnostic_sample.get("correlation_id") or ""), "sample correlation_id"
                )
                session_id = record_session
                if correlation_id != record_correlation:
                    raise BenchmarkError(f"sample correlation IDs disagree in {artifact}")
                recomputed_failures = validate_export(
                    sample["diagnostic"], str(sample["route"]), sample.get("correctness") or {},
                    expected_correlation=correlation_id,
                    expected_session=session_id,
                    expected_invocation=sample["invocation"],
                    expected_ordinal=sample["ordinal"],
                )
                if sorted(recomputed_failures) != sorted(sample.get("invalid_reasons") or []):
                    raise BenchmarkError(f"sample validity evidence mismatch in {artifact}")
                if sample["valid"] != (not recomputed_failures):
                    raise BenchmarkError(f"sample valid flag disagrees with evidence in {artifact}")
                register_unique(identity, sample_identities, "sample identity")
                register_unique(correlation_id, correlation_ids, "sample correlation identity")
                register_unique(session_id, session_ids, "sample session identity")
                ordinal_key = (artifact_id, sample["invocation"], sample["ordinal"])
                if ordinal_key in ordinal_identity_map:
                    raise BenchmarkError(f"duplicate ordinal identity mapping: {ordinal_key}")
                ordinal_identity_map[ordinal_key] = (correlation_id, session_id)
                artifact_samples.append(sample)
            try:
                validate_sample_ordinals(artifact_samples, expected_sample_count)
            except BenchmarkError as error:
                raise BenchmarkError(f"{error} in {artifact}") from error
            samples.extend(artifact_samples)
            key = "/".join(str(item[field]) for field in ("process_state", "checkout_kind", "route", "width"))
            resource_file = artifact / "resources.json"
            if not resource_file.exists():
                raise BenchmarkError(f"run artifact omitted resources.json: {artifact}")
            resource_value = json.loads(resource_file.read_text(encoding="utf-8"))
            metrics_value = find_value(resource_value, "metrics")
            resource_failures = validate_resource_evidence(metrics_value)
            if resource_failures:
                raise BenchmarkError(
                    f"invalid CPU/RSS resource evidence in {artifact}: {resource_failures}"
                )
            resource_records.setdefault(key, []).append(metrics_value)
        elif isinstance(item.get("results"), dict):
            correctness.append(item["results"])
        else:
            raise BenchmarkError(f"unsupported artifact kind: {artifact}")
        cleanup_file = artifact / "cleanup.json"
        if not cleanup_file.exists():
            raise BenchmarkError(f"artifact omitted cleanup.json: {artifact}")
        cleanup_value = json.loads(cleanup_file.read_text(encoding="utf-8"))
        entries = [entry for entry in cleanup_value if isinstance(entry, dict)] if isinstance(cleanup_value, list) else []
        teardown_results.append(validate_cleanup_evidence(
            entries, run_artifact=is_run, expected_agent_count=expected_sample_count,
            expected_worktree_count=expected_sample_count if is_run else 2,
        ))
        if item.get("cleanup_complete") is not True:
            teardown_results.append(False)
        if is_run:
            state_file = artifact / "state.json"
            if not state_file.exists():
                raise BenchmarkError(f"run artifact omitted state.json: {artifact}")
            state_value = json.loads(state_file.read_text(encoding="utf-8"))
            state_sessions = state_value.get("sessions", [])
            artifact_session_ids = {str(sample["session_id"]).upper() for sample in artifact_samples}
            teardown_results.append(
                len(state_sessions) == expected_sample_count
                and {str(session.get("session_id", "")).upper() for session in state_sessions}
                == artifact_session_ids
                and all(session.get("terminal") is True for session in state_sessions)
                and state_value.get("memory_stopped") is True
                and state_value.get("route_restored") is True
                and state_value.get("scope_reset") is True
                and state_value.get("benchmark_gate_unchanged") is True
            )
    external_evidence: dict[str, dict[str, Any]] = {}
    for raw in args.evidence or []:
        evidence = json.loads(Path(raw).expanduser().resolve(strict=True).read_text(encoding="utf-8"))
        if evidence.get("schema_version") != SCHEMA_VERSION or evidence.get("plan_sha256") != plan["plan_sha256"]:
            raise BenchmarkError(f"external evidence does not match plan: {raw}")
        scenario = evidence.get("scenario")
        if not isinstance(scenario, str) or scenario in external_evidence:
            raise BenchmarkError(f"duplicate or invalid external evidence scenario: {scenario}")
        external_evidence[scenario] = evidence
    cohorts: dict[str, dict[str, Any]] = {}
    grouped: dict[str, list[dict[str, Any]]] = {}
    for sample in samples:
        key = "/".join(str(sample.get(field)) for field in ("process_state", "checkout_kind", "route", "width"))
        grouped.setdefault(key, []).append(sample)
    for key, members in grouped.items():
        retained = [item for item in members if not item.get("warmup") and item.get("valid")]
        invocation_count = sum(
            1
            for process_state, checkout_kind, route, width, _ in cohort_invocations
            if "/".join((process_state, checkout_kind, route, str(width))) == key
        )
        route_counts: dict[str, int] = {}
        fallback_counts: dict[str, int] = {}
        for item in retained:
            sample_payload = find_value(item.get("diagnostic"), "sample")
            if not isinstance(sample_payload, dict):
                continue
            for name, count in (sample_payload.get("route_counts") or {}).items():
                route_counts[name] = route_counts.get(name, 0) + count
            for name, count in (sample_payload.get("fallback_counts") or {}).items():
                fallback_counts[name] = fallback_counts.get(name, 0) + count
        cohorts[key] = {
            "attempted": len(members),
            "invocation_count": invocation_count,
            "valid_retained": len(retained),
            "invalid_retained": len([item for item in members if not item.get("warmup") and not item.get("valid")]),
            "invalid_attempted": len([item for item in members if not item.get("valid")]),
            "route_counts": route_counts,
            "fallback_counts": fallback_counts,
            "exact_actual_routes": (
                route_counts == {
                    name: count * len(retained)
                    for name, count in EXPECTED_ACTUAL_ROUTE_COUNTS[key.split("/")[2]].items()
                }
                and fallback_counts == {}
            ),
            "metrics": {
                metric: stats(
                    (
                        item["diagnostic"]["sample"]["durations_us"][metric]
                        for item in retained
                        if isinstance(item.get("diagnostic"), dict)
                        and isinstance(item["diagnostic"].get("sample"), dict)
                        and metric in (item["diagnostic"]["sample"].get("durations_us") or {})
                    ),
                    positive=True,
                    label=f"sample {metric}",
                )
                for metric in ALL_METRICS
            },
            "git_command_count": stats(
                (
                    number
                    for item in retained
                    if (number := diagnostic_number(item, "git", "command_count")) is not None
                ),
                label="Git command count",
            ),
            "git_duration_us": stats(
                (
                    number
                    for item in retained
                    if (number := diagnostic_number(item, "git", "duration_us")) is not None
                ),
                label="Git duration",
            ),
            "filesystem_operation_count": stats(
                (
                    number
                    for item in retained
                    if (number := diagnostic_number(item, "work", "operation_count", "filesystem")) is not None
                ),
                label="filesystem operation count",
            ),
            "filesystem_duration_us": stats(
                (
                    number
                    for item in retained
                    if (number := diagnostic_number(item, "work", "duration_us", "filesystem")) is not None
                ),
                label="filesystem duration",
            ),
            "resources": resource_records.get(key, []),
        }
    gates: dict[str, str] = {}
    improvement_values: list[float] = []
    other_latency_regressions: list[float] = []
    memory_regressions: list[float] = []
    invalid_memory_baseline = False
    expected_comparisons = 0
    expected_memory_comparisons = 0
    for state in ("cold", "warm", "aged"):
        for checkout in ("linked-worktree",):
            for width in (1, 2, 4, 8):
                forced = cohorts.get(f"{state}/{checkout}/forced-full/{width}")
                projected = cohorts.get(f"{state}/{checkout}/projected/{width}")
                for metric in METRICS:
                    expected_comparisons += 1
                    ratio = gate_ratio(
                        forced and forced["metrics"][metric]["p95"],
                        projected and projected["metrics"][metric]["p95"],
                    )
                    if ratio is not None:
                        improvement_values.append(ratio)
                for metric in TOOL_METRICS:
                    forced_p95 = forced and forced["metrics"][metric]["p95"]
                    projected_p95 = projected and projected["metrics"][metric]["p95"]
                    if forced_p95 not in (None, 0) and projected_p95 is not None:
                        other_latency_regressions.append((projected_p95 - forced_p95) / forced_p95)
                forced_resources = (forced or {}).get("resources") or []
                projected_resources = (projected or {}).get("resources") or []
                for memory_metric in (
                    "peak_resident_mb",
                    "final_resident_mb",
                    "peak_physical_footprint_mb",
                    "final_physical_footprint_mb",
                ):
                    expected_memory_comparisons += 1
                    forced_values = [item.get(memory_metric) for item in forced_resources if isinstance(item.get(memory_metric), (int, float))]
                    projected_values = [item.get(memory_metric) for item in projected_resources if isinstance(item.get(memory_metric), (int, float))]
                    regression = absolute_memory_regression(forced_values, projected_values)
                    if regression is not None:
                        memory_regressions.append(regression)
                    elif forced_resources and projected_resources:
                        invalid_memory_baseline = True
    gates["projected p95 improvement >= 40%"] = (
        "pass" if len(improvement_values) == expected_comparisons and min(improvement_values) >= 0.40 else
        "fail" if len(improvement_values) == expected_comparisons else "incomplete"
    )
    sample_correctness_mismatches = sum(
        1 for sample in samples
        if "content_oracle_mismatch" in sample.get("invalid_reasons", [])
    )
    mismatches = sample_correctness_mismatches + sum(
        1 for group in correctness for item in group.values() if not item.get("ok")
    )
    covered_correctness = {
        scenario for group in correctness for scenario, item in group.items() if item.get("ok") is True
    }
    correctness_complete = set(CORRECTNESS_SCENARIOS) <= covered_correctness
    gates["zero correctness mismatches"] = (
        "pass" if correctness_complete and mismatches == 0 else
        "fail" if mismatches else "incomplete"
    )
    invalid = sum(1 for sample in samples if not sample.get("valid"))
    gates["zero invalid attempted samples"] = (
        "pass" if samples and invalid == 0 else "fail" if samples else "incomplete"
    )
    projected_fallbacks = sum(
        1 for sample in samples
        if sample.get("route") == "projected"
        and "unexpected_fallback" in sample.get("invalid_reasons", [])
    )
    gates["zero eligible warm fallbacks"] = "pass" if samples and projected_fallbacks == 0 else "fail" if samples else "incomplete"
    gates["other p95 regression <= 5%"] = (
        "pass" if len(other_latency_regressions) == 3 * 1 * 4 * len(TOOL_METRICS)
        and max(other_latency_regressions) <= 0.05 else
        "fail" if len(other_latency_regressions) == 3 * 1 * 4 * len(TOOL_METRICS) else "incomplete"
    )
    gates["peak memory regression <= 10%"] = (
        "fail" if invalid_memory_baseline else
        "pass" if len(memory_regressions) == expected_memory_comparisons and max(memory_regressions) <= 0.10 else
        "fail" if len(memory_regressions) == expected_memory_comparisons else "incomplete"
    )
    required_matrix_keys = {
        f"{state}/{checkout}/{route}/{width}"
        for state in ("cold", "warm", "aged")
        for checkout in ("linked-worktree",)
        for route in ROUTES
        for width in (1, 2, 4, 8)
    }
    retained_per_series = int(plan["matrix"]["retained_samples_per_series"])
    warmups_per_series = int(plan["matrix"]["warmups_per_series"])
    invocations_per_series = int(plan["matrix"].get("invocations_per_series", 0))
    complete_matrix = required_matrix_keys == set(cohorts) and invocations_per_series > 0 and all(
        cohort_accounting_valid(
            cohorts[key], width=int(key.rsplit("/", 1)[1]),
            warmups=warmups_per_series, retained=retained_per_series,
            invocations=invocations_per_series,
        )
        for key in required_matrix_keys
    )
    gates["complete route/process/checkout/width matrix"] = "pass" if complete_matrix else "incomplete"
    exact_routes_complete = complete_matrix and all(
        cohorts[key]["exact_actual_routes"] is True for key in required_matrix_keys
    )
    gates["exact actual routes and zero fallbacks"] = (
        "pass" if exact_routes_complete else "fail" if complete_matrix else "incomplete"
    )
    attribution_complete = complete_matrix and all(
        cohorts[key]["git_command_count"]["count"] == cohorts[key]["valid_retained"]
        and cohorts[key]["git_duration_us"]["count"] == cohorts[key]["valid_retained"]
        and cohorts[key]["filesystem_operation_count"]["count"] == cohorts[key]["valid_retained"]
        and cohorts[key]["filesystem_duration_us"]["count"] == cohorts[key]["valid_retained"]
        for key in required_matrix_keys
    )
    gates["complete Git/filesystem attribution"] = "pass" if attribution_complete else "incomplete"
    cpu_complete = complete_matrix and all(
        len(cohorts[key]["resources"]) == invocations_per_series
        and all(not validate_resource_evidence(item) for item in cohorts[key]["resources"])
        for key in required_matrix_keys
    )
    gates["complete CPU attribution"] = "pass" if cpu_complete else "incomplete"
    gates["stable owned-resource teardown"] = (
        "pass" if teardown_results and all(teardown_results) else
        "fail" if teardown_results else "incomplete"
    )
    required_external = set(plan["matrix"]["required_external_evidence"])
    failed_external = [
        scenario for scenario, evidence in external_evidence.items()
        if scenario in required_external and evidence.get("status") == "fail"
    ]
    gates["required external process/main-root evidence"] = (
        "fail" if failed_external else
        "pass" if required_external <= {
            scenario for scenario, evidence in external_evidence.items() if evidence.get("status") == "pass"
        } else "incomplete"
    )
    decision = "pass" if gates and all(value == "pass" for value in gates.values()) else "fail" if any(value == "fail" for value in gates.values()) else "incomplete"
    aggregate_id = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
    summary = {
        "schema_version": SCHEMA_VERSION, "aggregate_id": aggregate_id, "created_at": utc_now(),
        "plan_sha256": plan["plan_sha256"], "decision": decision, "gates": gates,
        "cohorts": cohorts, "correctness": {
            "campaign_count": len(correctness), "mismatch_count": mismatches,
            "covered_scenarios": sorted(covered_correctness),
        },
        "external_evidence": external_evidence,
        "invalid_attempted_samples": invalid,
        "invalid_retained_samples": sum(
            1 for sample in samples if not sample.get("warmup") and not sample.get("valid")
        ),
        "identity": {
            "sample_count": len(samples), "unique_correlation_ids": len(correlation_ids),
            "unique_session_ids": len(session_ids),
            "ordinal_mapping_count": len(ordinal_identity_map),
        },
        "artifacts": artifacts,
    }
    output = Path(args.output).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    save_json(output / "summary.json", summary, exclusive=True)
    section = render_scoreboard(summary)
    secure_write(output / "scoreboard-section.md", section.encode(), exclusive=True)
    if args.append_scoreboard:
        if not args.confirm_append_scoreboard:
            raise BenchmarkError("--append-scoreboard requires --confirm-append-scoreboard")
        scoreboard = Path(args.append_scoreboard).expanduser().resolve(strict=True)
        existing = scoreboard.read_text(encoding="utf-8")
        if aggregate_id in existing:
            raise BenchmarkError("aggregate ID already exists in scoreboard")
        fd = os.open(scoreboard, os.O_WRONLY | os.O_APPEND)
        try:
            os.write(fd, ("\n" + section).encode())
            os.fsync(fd)
        finally:
            os.close(fd)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0 if decision == "pass" else 2 if decision == "incomplete" else 1


def cleanup_command(args: argparse.Namespace) -> int:
    if not args.confirm_live_debug_app or not args.confirm_owned_resources:
        raise BenchmarkError("cleanup requires live-app and owned-resource confirmations")
    artifact = Path(args.artifact).expanduser().resolve(strict=True)
    state = json.loads((artifact / "state.json").read_text(encoding="utf-8"))
    plan = load_plan(artifact / "plan.json")
    cli = resolve_cli(args.cli)
    root = Path(plan["scope"]["root_path"])
    runner = CLIRunner(cli, plan["scope"]["window_id"], root, artifact)
    verify_disposable_target(runner, plan, require_only_planned_root=False)
    actions: list[dict[str, Any]] = []
    for session in state.get("sessions", []):
        status = session.get("status") if session.get("terminal") else terminalize(runner, session["session_id"])
        session["status"], session["terminal"] = status, status in TERMINAL_STATES
        actions.append({
            "action": "terminalize_agent", "session_id": session["session_id"],
            "status": status, "terminal": session["terminal"],
        })
    memory_action = stop_and_verify_memory_sampler(runner)
    state["memory_stopped"] = memory_action["verified_stopped"]
    actions.append(memory_action)
    control = state.get("control_id")
    if control and not state.get("route_restored"):
        response = runner.call(
            "cleanup-restore-route", DEBUG_TOOL,
            diagnostic_payload(plan, "restore_flags", control_id=control), check=False,
        )
        state["route_restored"] = call_succeeded(response)
    actions.append({"action": "restore_route", "ok": state.get("route_restored") is True})
    if not state.get("scope_reset"):
        reset = runner.call(
            "cleanup-reset", DEBUG_TOOL, diagnostic_payload(plan, "reset"), check=False
        )
        state["scope_reset"] = call_succeeded(reset) and isinstance(find_value(reset, "reset"), dict)
    actions.append({"action": "reset_diagnostics", "ok": state.get("scope_reset") is True})
    try:
        require_benchmark_gate(runner)
        state["benchmark_gate_unchanged"] = True
    except BenchmarkError:
        state["benchmark_gate_unchanged"] = False
    actions.append({
        "action": "preserve_benchmark_setting", "ok": state["benchmark_gate_unchanged"],
    })
    for item in state.get("worktrees", []):
        actions.append(clean_owned_worktree(
            root, item["path"], all(session.get("terminal") for session in state.get("sessions", [])),
            expected_branch=item.get("branch"), expected_path=item.get("expected_path"),
        ))
    final_roots_restored = False
    try:
        verify_disposable_target(runner, plan, require_only_planned_root=True)
        final_roots_restored = True
    except BenchmarkError:
        pass
    actions.append({"action": "restore_workspace_roots", "ok": final_roots_restored})
    cleanup_complete = validate_cleanup_evidence(
        actions, run_artifact=True, expected_agent_count=len(state.get("sessions", [])),
        expected_worktree_count=len(state.get("worktrees", [])),
    )
    state["cleanup_complete"] = cleanup_complete
    save_json(artifact / "cleanup.json", actions)
    save_json(artifact / "state.json", state)
    print(json.dumps(actions, indent=2, sort_keys=True))
    return 0 if cleanup_complete else 1


def add_live_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--plan", required=True)
    parser.add_argument("--cli")
    parser.add_argument("--output-root", default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--confirm-live-debug-app", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    marker = sub.add_parser("create-marker", help="create the exclusive disposable-root ownership marker offline")
    marker.add_argument("--root-path", required=True)
    marker.add_argument("--workspace-id", required=True)
    marker.add_argument("--root-id", required=True)
    marker.add_argument("--owner-token", required=True)
    marker.add_argument("--confirm-disposable-root", action="store_true")
    marker.set_defaults(func=create_marker_command)

    self_test = sub.add_parser("self-test", help="run deterministic offline contract validation")
    self_test.set_defaults(func=self_test_command)

    plan = sub.add_parser("plan", help="write a non-live campaign plan")
    plan.add_argument("--workspace-name", required=True)
    plan.add_argument("--window-id", type=int, required=True)
    plan.add_argument("--workspace-id", required=True)
    plan.add_argument("--context-id", required=True)
    plan.add_argument("--root-id", required=True)
    plan.add_argument("--root-path", required=True)
    plan.add_argument("--owner-token", required=True)
    plan.add_argument("--dataset-label", required=True)
    plan.add_argument("--asserted-file-count", type=int, required=True)
    plan.add_argument("--base-ref", default="HEAD")
    plan.add_argument("--search-marker", required=True)
    plan.add_argument("--read-path", required=True)
    plan.add_argument("--read-marker", required=True)
    plan.add_argument("--code-file-type", default="swift")
    plan.add_argument("--warmups", type=int, default=1)
    plan.add_argument("--retained-samples", type=int, default=5)
    plan.add_argument("--invocations-per-series", type=int, default=3)
    plan.add_argument("--output", required=True)
    plan.set_defaults(func=plan_command)

    preflight = sub.add_parser("preflight", help="discover schemas and verify exact scope")
    add_live_common(preflight)
    preflight.set_defaults(func=preflight_command)

    evidence = sub.add_parser("record-evidence", help="write one reviewed external-evidence record offline")
    evidence.add_argument("--plan", required=True)
    evidence.add_argument("--scenario", required=True)
    evidence.add_argument("--status", choices=("pass", "fail"), required=True)
    evidence.add_argument("--details", help="optional JSON object with sanitized evidence details")
    evidence.add_argument("--output", required=True)
    evidence.set_defaults(func=record_evidence_command)

    run = sub.add_parser("run", help="run one route/process/width cohort")
    add_live_common(run)
    run.add_argument("--route", choices=sorted(ROUTES), required=True)
    run.add_argument("--process-state", choices=("cold", "warm", "aged"), required=True)
    run.add_argument("--checkout-kind", choices=("linked-worktree",), default="linked-worktree")
    run.add_argument("--width", type=int, choices=(1, 2, 4, 8), required=True)
    run.add_argument("--invocation", type=int, required=True)
    run.add_argument("--warmups", type=int, default=1)
    run.add_argument("--samples", type=int, default=5)
    run.add_argument("--minimum-aged-sessions", type=int, default=32)
    run.add_argument("--confirm-process-state", action="store_true")
    run.set_defaults(func=run_command)

    smoke = sub.add_parser("smoke", help="run correctness, watcher, inheritance, and root-churn checks")
    add_live_common(smoke)
    smoke.add_argument("--confirm-dedicated-workspace", action="store_true")
    smoke.set_defaults(func=smoke_command)

    aggregate = sub.add_parser("aggregate", help="aggregate existing artifacts offline")
    aggregate.add_argument("--plan", required=True)
    aggregate.add_argument("--artifact", action="append", required=True)
    aggregate.add_argument("--evidence", action="append")
    aggregate.add_argument("--output", required=True)
    aggregate.add_argument("--append-scoreboard")
    aggregate.add_argument("--confirm-append-scoreboard", action="store_true")
    aggregate.set_defaults(func=aggregate_command)

    cleanup = sub.add_parser("cleanup", help="resume idempotent cleanup for an interrupted run")
    cleanup.add_argument("--artifact", required=True)
    cleanup.add_argument("--cli")
    cleanup.add_argument("--confirm-live-debug-app", action="store_true")
    cleanup.add_argument("--confirm-owned-resources", action="store_true")
    cleanup.set_defaults(func=cleanup_command)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except BenchmarkError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted; run the cleanup subcommand for any recorded live artifact", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
