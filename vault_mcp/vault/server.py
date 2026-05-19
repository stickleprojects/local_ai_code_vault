from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable


def _optional_arg(arguments: dict[str, Any], key: str, flag: str) -> list[str]:
    if key in arguments and arguments[key] is not None:
        return [flag, str(arguments[key])]
    return []

TOOL_DEFS: dict[str, dict[str, Any]] = {
    "vault_health": {
        "description": "Run scripts/vault-health.ps1 to check stack reachability.",
        "schema": {"type": "object", "properties": {}, "additionalProperties": False},
        "script": "vault-health.ps1",
        "argv": lambda _a: [],
    },
    "vault_status": {
        "description": "Run scripts/vault-status.ps1 for registration/index staleness.",
        "schema": {
            "type": "object",
            "properties": {"path": {"type": "string", "default": "."}},
            "additionalProperties": False,
        },
        "script": "vault-status.ps1",
        "argv": lambda a: ["-Path", a.get("path", ".")],
    },
    "vault_index": {
        "description": "Run scripts/index-repo.ps1 to index a repository.",
        "schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "default": "."},
                "incremental": {"type": "boolean", "default": False},
                "wait": {"type": "boolean", "default": False},
                "build": {"type": "boolean", "default": False},
            },
            "additionalProperties": False,
        },
        "script": "index-repo.ps1",
        "argv": lambda a: [
            "-Path",
            a.get("path", "."),
            *(["-Incremental"] if a.get("incremental") else []),
            *(["-Wait"] if a.get("wait") else []),
            *(["-Build"] if a.get("build") else []),
        ],
    },
    "vault_search": {
        "description": "Run scripts/query-smart.ps1 for semantic search with auto-index + fallback.",
        "schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "path": {"type": "string", "default": "."},
                "limit": {"type": "integer", "minimum": 1},
                "doNotIndex": {"type": "boolean", "default": False},
                "build": {"type": "boolean", "default": False},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
        "script": "query-smart.ps1",
        "argv": lambda a: [
            a["query"],
            "-Path",
            a.get("path", "."),
            *_optional_arg(a, "limit", "-Limit"),
            *(["-DoNotIndex"] if a.get("doNotIndex") else []),
            *(["-Build"] if a.get("build") else []),
        ],
    },
    "vault_savings": {
        "description": "Run scripts/vault-savings.ps1 for token-savings estimates.",
        "schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "default": "."},
                "days": {"type": "integer", "minimum": 1, "maximum": 365},
            },
            "additionalProperties": False,
        },
        "script": "vault-savings.ps1",
        "argv": lambda a: [
            "-Path",
            a.get("path", "."),
            *_optional_arg(a, "days", "-Days"),
        ],
    },
    "vault_inspect": {
        "description": "Run scripts/vault-inspect.ps1 for read-only stats/inventory.",
        "schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "default": "."},
                "files": {"type": "boolean", "default": False},
                "language": {"type": "string"},
                "offset": {"type": "integer", "minimum": 0},
                "limit": {"type": "integer", "minimum": 1},
            },
            "additionalProperties": False,
        },
        "script": "vault-inspect.ps1",
        "argv": lambda a: [
            "-Path",
            a.get("path", "."),
            *(["-Files"] if a.get("files") else []),
            *(["-Language", a.get("language")] if a.get("language") else []),
            *_optional_arg(a, "offset", "-Offset"),
            *_optional_arg(a, "limit", "-Limit"),
        ],
    },
    "vault_hooks": {
        "description": "Run scripts/install-git-hooks.ps1 to install/remove vault hooks.",
        "schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "default": "."},
                "remove": {"type": "boolean", "default": False},
                "force": {"type": "boolean", "default": False},
            },
            "additionalProperties": False,
        },
        "script": "install-git-hooks.ps1",
        "argv": lambda a: [
            "-Path",
            a.get("path", "."),
            *(["-Remove"] if a.get("remove") else []),
            *(["-Force"] if a.get("force") else []),
        ],
    },
}


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _vault_home() -> Path:
    raw = os.environ.get("VAULT_HOME")
    if not raw:
        raise RuntimeError("VAULT_HOME is not set. Run scripts/install-copilot.ps1 first.")
    return Path(raw).resolve()


def script_command(script_name: str, script_args: list[str]) -> list[str]:
    script_path = _vault_home() / "scripts" / script_name
    return ["pwsh", "-NoProfile", "-File", str(script_path), *script_args]


def _run_script(script_name: str, argv: list[str]) -> tuple[dict[str, Any], int]:
    command = script_command(script_name, argv)
    try:
        proc = subprocess.run(command, capture_output=True, text=True, check=False)
    except Exception as exc:  # pragma: no cover - process launch failure is environment-specific
        return {"ok": False, "code": 2, "error": str(exc)}, 2

    stdout = (proc.stdout or "").strip()
    parsed: dict[str, Any] | None = None
    if stdout:
        try:
            obj = json.loads(stdout)
            if isinstance(obj, dict):
                parsed = obj
        except json.JSONDecodeError:
            parsed = None

    result: dict[str, Any] = parsed or {
        "ok": proc.returncode == 0,
        "code": proc.returncode,
        "stdout_raw": stdout,
    }
    result.setdefault("ok", proc.returncode == 0)
    result.setdefault("code", proc.returncode)
    stderr = (proc.stderr or "").strip()
    if stderr:
        result["stderr"] = stderr
    return result, proc.returncode


def run_tool(name: str, arguments: dict[str, Any] | None) -> tuple[dict[str, Any], int]:
    if name not in TOOL_DEFS:
        return {"ok": False, "code": 2, "error": f"Unknown tool '{name}'"}, 2
    tool = TOOL_DEFS[name]
    argv_builder: Callable[[dict[str, Any]], list[str]] = tool["argv"]
    args = arguments or {}
    try:
        argv = argv_builder(args)
    except Exception as exc:
        return {"ok": False, "code": 2, "error": str(exc)}, 2
    return _run_script(tool["script"], argv)


def _tool_list_result() -> dict[str, Any]:
    return {
        "tools": [
            {
                "name": name,
                "description": spec["description"],
                "inputSchema": spec["schema"],
            }
            for name, spec in TOOL_DEFS.items()
        ]
    }


def _read_message() -> dict[str, Any] | None:
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        text = line.decode("utf-8").strip()
        if not text:
            continue
        return json.loads(text)


def _write_message(message: dict[str, Any]) -> None:
    payload = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.buffer.write(payload.encode("utf-8"))
    sys.stdout.buffer.write(b"\n")
    sys.stdout.buffer.flush()


def _response(req_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _error(req_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}


def _dispatch(method: str, params: dict[str, Any] | None) -> dict[str, Any]:
    if method == "initialize":
        return {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "vault-mcp", "version": "0.1.0"},
        }
    if method == "tools/list":
        return _tool_list_result()
    if method == "tools/call":
        if not params or "name" not in params:
            raise ValueError("Missing tools/call params.name")
        payload, code = run_tool(params["name"], params.get("arguments") or {})
        return {
            "content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}],
            "structuredContent": payload,
            "isError": code != 0,
        }
    if method == "ping":
        return {}
    raise ValueError(f"Method not found: {method}")


def main() -> int:
    while True:
        request = _read_message()
        if request is None:
            return 0

        method = request.get("method")
        req_id = request.get("id")
        if not method:
            if req_id is not None:
                _write_message(_error(req_id, -32600, "Invalid Request"))
            continue

        if req_id is None:
            if method == "notifications/initialized":
                continue
            # ignore other notifications
            continue

        try:
            result = _dispatch(method, request.get("params"))
            _write_message(_response(req_id, result))
        except ValueError as exc:
            _write_message(_error(req_id, -32601, str(exc)))
        except Exception as exc:  # pragma: no cover - safety net
            _write_message(_error(req_id, -32000, str(exc)))


if __name__ == "__main__":
    raise SystemExit(main())
