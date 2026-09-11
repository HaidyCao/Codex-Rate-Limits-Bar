"""Isolated CLI/MCP checks; fake credentials/server, no real session or cache writes."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/release/CodexRateLimitsBar").resolve()
    with tempfile.TemporaryDirectory(prefix="codex-usage-integration-") as directory:
        root = Path(directory)
        profile, sessions = root / "profile", root / "sessions"
        profile.mkdir()
        sessions.mkdir()
        claims = base64.urlsafe_b64encode(json.dumps({"sub": "fixture-user"}).encode()).decode().rstrip("=")
        (profile / "auth.json").write_text(json.dumps({"tokens": {
            "account_id": "fixture-account", "id_token": f"h.{claims}.s", "access_token": "fixture-access"
        }}))
        fake = root / "fake-codex"
        fake.write_text("""#!/usr/bin/env python3
import json, os, sys
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method == 'account/read':
        result = {'account': {'type': 'chatgpt', 'email': 'fixture@example.invalid', 'planType': 'pro'}}
    elif method == 'account/rateLimits/read':
        result = {'rateLimits': {'limitId': 'codex', 'secondary': {'usedPercent': 30,
            'windowDurationMins': 10080, 'resetsAt': int(os.environ['FIXTURE_RESET_AT'])},
            'credits': {'hasCredits': True, 'unlimited': False, 'balance': '12.5'}},
            'rateLimitResetCredits': {'availableCount': 3, 'credits': None}}
    else:
        result = {}
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
""")
        fake.chmod(0o700)
        env = os.environ.copy()
        env.update(CODEX_HOME=str(profile), CODEX_SESSIONS_DIR=str(sessions), CODEX_BIN=str(fake),
                   FIXTURE_RESET_AT=str(int(datetime.now(timezone.utc).timestamp()) + 86400))
        timestamp = (datetime.now(timezone.utc) - timedelta(seconds=5)).isoformat().replace("+00:00", "Z")

        def run(*args, input=None):
            return subprocess.run([str(binary), *args], input=input, env=env, text=True,
                                  capture_output=True, timeout=30, check=True).stdout

        def mcp(name):
            messages = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                    "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": {}}},
            ]
            responses = [json.loads(line) for line in run("mcp", input="".join(json.dumps(m) + "\n" for m in messages)).splitlines()]
            return json.loads(next(r for r in responses if r.get("id") == 2)["result"]["content"][0]["text"])

        def write_usage(complete=True):
            context = {"model": "gpt-5.6-sol"}
            info = {"total_token_usage": {"input_tokens": 1000, "total_tokens": 1000}}
            if complete:
                context["service_tier"] = "standard"
                info["last_token_usage"] = {"input_tokens": 1000}
            events = [
                {"payload": {"id": "fixture-session"}, "timestamp": timestamp, "type": "session_meta"},
                {"payload": context, "timestamp": timestamp, "type": "turn_context"},
                {"payload": {"info": info, "type": "token_count"}, "timestamp": timestamp, "type": "event_msg"},
            ]
            # Default separators contain legal spaces; root type follows payload.
            data = "".join(json.dumps(event) + "\n" for event in events)
            (sessions / "usage.jsonl").write_text(data)
            (sessions / "renamed-copy.jsonl").write_text(data)

        def check_shared_status(expected):
            direct = json.loads(run("local-usage", "--rebuild"))
            shared = mcp("get_codex_local_usage")
            status = json.loads(run("status"))
            combined = mcp("get_codex_status")
            for value in [direct, shared, status["localUsage"], combined["localUsage"]]:
                assert value["diagnostics"]["status"] == expected, value["diagnostics"]
                for key in ["diagnostics", "billingAssumptions", "todayCost", "todayCredits"]:
                    assert value[key] == direct[key], key
                assert value["display"]["scanStatusLabel"] == direct["display"]["scanStatusLabel"]
            assert status.get("localUsageError") == direct.get("error")
            assert status["accountContext"] == status["localUsage"]["accountContext"]
            assert status["resetCredits"]["availableCount"] == 3
            assert status["rateLimits"]["credits"]["balance"] == "12.5"
            valuation = status["localUsage"]["weeklyQuotaCost"]["valuation"]
            assert valuation["method"] == "local-api-intervals-v1"
            assert valuation["lastQuotaSampleAtIso"] == status["fetchedAtIso"]
            assert valuation["effectiveIntervalCount"] == 0
            assert valuation["status"] == ("paused" if expected in ("partial", "unavailable") else "collecting")
            assert status["localUsage"]["weeklyQuotaCost"].get("estimatedQuotaUSD") is None
            return direct

        write_usage()
        complete = check_shared_status("complete")
        assert complete["totalTokens"] == 1000
        assert complete["billingAssumptions"]["apiPercent"] == 0
        assert len(complete["topFiles"][0]["sourceFiles"]) == 2
        write_usage(complete=False)
        assumed = check_shared_status("complete")
        assert assumed["todayCost"]["coveragePercent"] == 100
        assert assumed["billingAssumptions"]["creditPercent"] == 100
        bad = sessions / "bad.jsonl"
        bad.write_text("not json\n")
        assert check_shared_status("partial")["diagnostics"]["parseErrorCount"] == 1
        bad.chmod(0)
        try:
            assert check_shared_status("partial")["diagnostics"]["readFailureCount"] == 1
        finally:
            bad.chmod(0o600)
        bad.unlink()
        check_shared_status("complete")
        for path in sessions.iterdir():
            path.unlink()
        check_shared_status("empty")
        bad.write_text("{broken json}\n")
        unavailable = check_shared_status("unavailable")
        assert "--" in unavailable["display"]["consumptionLabel"]
    print("CLI/MCP integration passed: completeness, assumptions, recovery, account attribution and timestamped weekly evidence.")


if __name__ == "__main__":
    main()
