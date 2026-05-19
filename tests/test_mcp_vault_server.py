import importlib
import io
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

server = importlib.import_module("vault_mcp.vault.server")


def test_script_command_uses_vault_home(monkeypatch):
    monkeypatch.setenv("VAULT_HOME", "/tmp/vault-home")
    cmd = server.script_command("vault-health.ps1", [])
    # Separator-agnostic: the impl emits OS-native paths (backslashes on
    # Windows), so compare normalized Paths, not literal POSIX strings.
    assert cmd[:3] == ["pwsh", "-NoProfile", "-File"]
    assert len(cmd) == 4
    assert Path(cmd[3]) == Path("/tmp/vault-home").resolve() / "scripts" / "vault-health.ps1"


def test_run_tool_builds_expected_args(monkeypatch):
    monkeypatch.setenv("VAULT_HOME", "/tmp/vault-home")
    captured = {}

    def fake_run(command, capture_output, text, check):
        captured["command"] = command
        return SimpleNamespace(stdout='{"ok":true,"code":0}', stderr="", returncode=0)

    monkeypatch.setattr(server.subprocess, "run", fake_run)
    payload, code = server.run_tool("vault_index", {"path": "/repo", "incremental": True, "wait": True, "build": True})

    assert code == 0
    assert payload["ok"] is True
    # Script path is OS-native (str(Path)); rebuild it the same way so
    # the assertion holds on Windows and POSIX alike.
    expected_script = str(Path("/tmp/vault-home").resolve() / "scripts" / "index-repo.ps1")
    assert captured["command"] == [
        "pwsh",
        "-NoProfile",
        "-File",
        expected_script,
        "-Path",
        "/repo",
        "-Incremental",
        "-Wait",
        "-Build",
    ]


def test_run_tool_builds_expected_args_for_vault_savings(monkeypatch):
    monkeypatch.setenv("VAULT_HOME", "/tmp/vault-home")
    captured = {}

    def fake_run(command, capture_output, text, check):
        captured["command"] = command
        return SimpleNamespace(stdout='{"ok":true,"code":0}', stderr="", returncode=0)

    monkeypatch.setattr(server.subprocess, "run", fake_run)
    payload, code = server.run_tool("vault_savings", {"path": "/repo", "days": 30})

    assert code == 0
    assert payload["ok"] is True
    expected_script = str(Path("/tmp/vault-home").resolve() / "scripts" / "vault-savings.ps1")
    assert captured["command"] == [
        "pwsh",
        "-NoProfile",
        "-File",
        expected_script,
        "-Path",
        "/repo",
        "-Days",
        "30",
    ]


def test_run_tool_builds_expected_args_for_vault_search_smart(monkeypatch):
    monkeypatch.setenv("VAULT_HOME", "/tmp/vault-home")
    captured = {}

    def fake_run(command, capture_output, text, check):
        captured["command"] = command
        return SimpleNamespace(stdout='{"ok":true,"code":0}', stderr="", returncode=0)

    monkeypatch.setattr(server.subprocess, "run", fake_run)
    payload, code = server.run_tool(
        "vault_search",
        {
            "query": "rename surname",
            "path": "/repo",
            "limit": 5,
            "doNotIndex": True,
            "build": True,
        },
    )

    assert code == 0
    assert payload["ok"] is True
    expected_script = str(Path("/tmp/vault-home").resolve() / "scripts" / "query-smart.ps1")
    assert captured["command"] == [
        "pwsh",
        "-NoProfile",
        "-File",
        expected_script,
        "rename surname",
        "-Path",
        "/repo",
        "-Limit",
        "5",
        "-DoNotIndex",
        "-Build",
    ]


def test_run_tool_returns_error_for_unknown():
    payload, code = server.run_tool("unknown", {})
    assert code == 2
    assert payload["ok"] is False


def test_dispatch_tools_call_wraps_script_payload(monkeypatch):
    monkeypatch.setenv("VAULT_HOME", "/tmp/vault-home")

    def fake_run(command, capture_output, text, check):
        return SimpleNamespace(stdout='{"ok":false,"code":5,"error":"not indexed"}', stderr="", returncode=5)

    monkeypatch.setattr(server.subprocess, "run", fake_run)
    result = server._dispatch("tools/call", {"name": "vault_status", "arguments": {"path": "/repo"}})

    assert result["isError"] is True
    body = json.loads(result["content"][0]["text"])
    assert body["code"] == 5
    assert result["structuredContent"]["error"] == "not indexed"


def test_script_command_requires_vault_home(monkeypatch):
    monkeypatch.delenv("VAULT_HOME", raising=False)
    with pytest.raises(RuntimeError):
        server.script_command("vault-health.ps1", [])


def test_read_message_parses_jsonl(monkeypatch):
    monkeypatch.setattr(server.sys, "stdin", SimpleNamespace(buffer=io.BytesIO(b'{"jsonrpc":"2.0","id":1}\n')))
    message = server._read_message()
    assert message == {"jsonrpc": "2.0", "id": 1}


def test_write_message_emits_jsonl(monkeypatch):
    output = io.BytesIO()
    monkeypatch.setattr(server.sys, "stdout", SimpleNamespace(buffer=output))
    server._write_message({"jsonrpc": "2.0", "id": 1, "result": {}})
    assert output.getvalue().endswith(b"\n")
    assert b"Content-Length:" not in output.getvalue()


def test_tools_list_includes_vault_savings():
    tools = server._tool_list_result()["tools"]
    names = {t["name"] for t in tools}
    assert "vault_savings" in names
