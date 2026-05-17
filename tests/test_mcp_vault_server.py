import importlib
import json

import pytest

server = importlib.import_module("mcp.vault.server")


def test_script_command_uses_vault_home(monkeypatch):
    monkeypatch.setenv("VAULT_HOME", "/tmp/vault-home")
    cmd = server.script_command("vault-health.ps1", [])
    assert cmd[:4] == ["pwsh", "-NoProfile", "-File", "/tmp/vault-home/scripts/vault-health.ps1"]


def test_run_tool_builds_expected_args(monkeypatch):
    monkeypatch.setenv("VAULT_HOME", "/tmp/vault-home")
    captured = {}

    def fake_run(command, capture_output, text, check):
        captured["command"] = command
        return type("P", (), {"stdout": '{"ok":true,"code":0}', "stderr": "", "returncode": 0})()

    monkeypatch.setattr(server.subprocess, "run", fake_run)
    payload, code = server.run_tool("vault_index", {"path": "/repo", "incremental": True, "wait": True, "build": True})

    assert code == 0
    assert payload["ok"] is True
    assert captured["command"] == [
        "pwsh",
        "-NoProfile",
        "-File",
        "/tmp/vault-home/scripts/index-repo.ps1",
        "-Path",
        "/repo",
        "-Incremental",
        "-Wait",
        "-Build",
    ]


def test_run_tool_returns_error_for_unknown():
    payload, code = server.run_tool("unknown", {})
    assert code == 2
    assert payload["ok"] is False


def test_dispatch_tools_call_wraps_script_payload(monkeypatch):
    monkeypatch.setenv("VAULT_HOME", "/tmp/vault-home")

    def fake_run(command, capture_output, text, check):
        return type("P", (), {"stdout": '{"ok":false,"code":5,"error":"not indexed"}', "stderr": "", "returncode": 5})()

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
