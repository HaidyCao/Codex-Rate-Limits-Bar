"""Isolated CLI/MCP checks; fake credentials/server, no real session or cache writes."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Support"))
from verification_support import isolated_environment, offline_command, run_checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", default=".build/release/CodexRateLimitsBar", type=Path)
    parser.add_argument("--artifacts", type=Path, help="Save isolated status fixtures for AppKit verification")
    args = parser.parse_args()
    binary = args.binary.resolve()
    artifacts = args.artifacts.resolve() if args.artifacts else None
    if artifacts:
        artifacts.mkdir(parents=True, exist_ok=True)

    def save(name, value):
        if artifacts:
            (artifacts / (name + ".json")).write_text(json.dumps(value, indent=2))
    with tempfile.TemporaryDirectory(prefix="codex-usage-integration-") as directory:
        root = Path(directory)
        env = isolated_environment(root)
        profile, sessions = Path(env["CODEX_HOME"]), Path(env["CODEX_SESSIONS_DIR"])
        claims = base64.urlsafe_b64encode(json.dumps({"sub": "fixture-user"}).encode()).decode().rstrip("=")
        (profile / "auth.json").write_text(json.dumps({"tokens": {
            "account_id": "fixture-account", "id_token": f"h.{claims}.s", "access_token": "fixture-access"
        }}))
        fake = root / "fake-codex"
        fake.write_text("""#!/usr/bin/env python3
import json, os, sys, signal, time
if os.environ.get('FIXTURE_MODE') == 'hang':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(os.environ['FIXTURE_PID_FILE'], 'w') as handle:
        handle.write(str(os.getpid()))
    while True:
        time.sleep(1)
for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method == 'account/read':
        result = {'account': {'type': 'chatgpt', 'email': 'fixture@example.invalid', 'planType': 'pro'}}
    elif method == 'account/rateLimits/read':
        if os.environ.get('FIXTURE_MODE') == 'failure':
            print(json.dumps({'id': request['id'], 'error': {'code': -1, 'message': 'fixture offline'}}), flush=True)
            continue
        result = {'rateLimits': {'limitId': 'codex', 'secondary': {'usedPercent': 30,
            'windowDurationMins': 10080, 'resetsAt': int(os.environ['FIXTURE_RESET_AT'])},
            'credits': {'hasCredits': True, 'unlimited': False, 'balance': '12.5'}},
            'rateLimitResetCredits': {'availableCount': 3, 'credits': None}}
        if os.environ.get('FIXTURE_MODE') == 'missing':
            del result['rateLimits']['credits']
            result['rateLimitResetCredits'] = {}
        if os.environ.get('FIXTURE_MODE') == 'missing-percent':
            del result['rateLimits']['secondary']['usedPercent']
        if os.environ.get('FIXTURE_MODE') == 'invalid-numbers':
            result['rateLimits']['secondary']['usedPercent'] = 1e100
            result['rateLimits']['secondary']['resetsAt'] = 1e100
            result['rateLimits']['credits'] = {'unlimited': 2, 'balance': 'NaN'}
            result['rateLimitResetCredits'] = {'availableCount': 1e100, 'credits': []}
    else:
        result = {}
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
""")
        fake.chmod(0o700)
        env.update(CODEX_BIN=str(fake),
                   FIXTURE_RESET_AT=str(int(datetime.now(timezone.utc).timestamp()) + 86400))
        # Keep the fixture near local noon even when verification starts at UTC
        # midnight. Explicit midnight rollover remains covered by Swift clocks.
        offset = 12 - datetime.now(timezone.utc).hour
        env["TZ"] = f"Etc/GMT{-offset:+d}" if offset else "Etc/GMT"
        timestamp = (datetime.now(timezone.utc) - timedelta(seconds=5)).isoformat().replace("+00:00", "Z")

        def run(*args, input=None):
            return run_checked(offline_command([binary, *args]), input=input, env=env, text=True,
                               capture_output=True, timeout=45).stdout

        builtin = json.loads(run("pricing", "--export-builtin"))
        pricing_file = root / "pricing.json"
        pricing_file.write_text(json.dumps(builtin))
        env["CODEX_PRICING_FILE"] = str(pricing_file)
        assert json.loads(run("pricing", "--validate", str(pricing_file)))["source"] == "custom"

        def mcp(name):
            messages = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                    "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": {}}},
            ]
            responses = [json.loads(line) for line in run("mcp", input="".join(json.dumps(m) + "\n" for m in messages)).splitlines()]
            return json.loads(next(r for r in responses if r.get("id") == 2)["result"]["content"][0]["text"])

        def write_usage(complete=True, model="gpt-5.6-sol", tier="standard", breakdown=True):
            context = {"model": model}
            info = {"total_token_usage": {"input_tokens": 1000, "total_tokens": 1000}}
            if not breakdown:
                del info["total_token_usage"]["input_tokens"]
            if complete:
                context["service_tier"] = tier
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

        def check_shared_status(expected, artifact=None):
            direct = json.loads(run("local-usage", "--rebuild"))
            shared = mcp("get_codex_local_usage")
            status = json.loads(run("status"))
            combined = mcp("get_codex_status")
            for value in [direct, shared, status["localUsage"], combined["localUsage"]]:
                assert value["diagnostics"]["status"] == expected, value["diagnostics"]
                phase = "failed" if expected == "unavailable" else "partial" if expected == "partial" else "success"
                assert value["freshness"]["status"] == phase, value["freshness"]
                assert bool(value["freshness"].get("lastSuccessAtIso")) == (phase == "success")
                assert bool(value["freshness"].get("dataAtIso")) == (phase != "failed")
                for key in ["diagnostics", "billingAssumptions", "todayCost", "todayCredits", "pricing", "unpricedUsage"]:
                    assert value[key] == direct[key], key
                assert value["display"]["scanStatusLabel"] == direct["display"]["scanStatusLabel"]
            for value in [status, combined]:
                assert value["refresh"]["quota"]["status"] == "success"
                assert value["refresh"]["credits"]["status"] == "success"
                assert value["refresh"]["resetCredits"]["status"] == "partial"
                assert value["resetCredits"]["freshness"]["status"] == "partial"
                assert value["refresh"]["localUsage"]["status"] == direct["freshness"]["status"]
            if artifact:
                save(artifact, status)
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
        complete = check_shared_status("complete", "complete")
        assert complete["totalTokens"] == 1000
        assert complete["billingAssumptions"]["apiPercent"] == 0
        assert len(complete["topFiles"][0]["sourceFiles"]) == 2

        write_usage(breakdown=False)
        missing_breakdown = check_shared_status("complete", "missing-breakdown")
        assert missing_breakdown["totalTokens"] == 1000
        for key, amount in [("todayCost", "estimatedCostUSD"), ("todayCredits", "estimatedCredits")]:
            assert missing_breakdown[key].get(amount) is None
            assert missing_breakdown[key]["coveragePercent"] == 0
            assert missing_breakdown[key]["unpricedTokens"] == 1000
        assert {entry["reason"] for entry in missing_breakdown["unpricedUsage"]} == {"incompleteTokenBreakdown"}

        write_usage(model="Raw-Private-Model", tier="private-mode")
        unknown = check_shared_status("complete", "unknown")
        assert unknown["todayCost"]["unpricedTokens"] == 1000
        assert unknown["todayCredits"]["unpricedTokens"] == 1000
        assert all(entry["model"] == "Raw-Private-Model" and entry["serviceTier"] == "private-mode"
                   and entry["totalTokens"] == 1000 and entry["percent"] == 100 for entry in unknown["unpricedUsage"])
        custom = json.loads(json.dumps(builtin))
        custom["api"]["version"] = "manual-api-v2"
        custom["api"]["aliases"]["raw-private-model"] = "gpt-5.6-sol"
        custom["api"]["models"]["gpt-5.6-sol"]["input"] = 8
        custom["credits"]["version"] = "manual-credits-v2"
        custom["credits"]["aliases"]["raw-private-model"] = "gpt-5.6-terra"
        custom["credits"]["models"]["gpt-5.6-terra"]["serviceTiers"]["private-mode"] = 3
        pricing_file.write_text(json.dumps(custom))
        assert json.loads(run("pricing", "--validate", str(pricing_file)))["api"]["version"] == "manual-api-v2"
        mapped = check_shared_status("complete")
        assert mapped["todayCost"]["estimatedCostUSD"] == 0.008
        assert mapped["todayCredits"]["estimatedCredits"] == 0.15
        assert mapped["todayCost"]["models"][0]["pricingSource"] == "custom"
        assert not mapped["unpricedUsage"]
        custom["api"]["models"]["gpt-5.6-sol"]["input"] = -1
        pricing_file.write_text(json.dumps(custom))
        rejected = subprocess.run(offline_command([binary, "pricing", "--validate", pricing_file]), env=env,
                                  text=True, capture_output=True, timeout=30)
        assert rejected.returncode != 0
        fallback = check_shared_status("complete")
        assert fallback["pricing"]["configurationError"]
        assert fallback["pricing"]["source"] == "builtin"
        assert fallback["todayCost"]["unpricedTokens"] == 1000
        pricing_file.write_text(json.dumps(builtin))
        write_usage(complete=False)
        assumed = check_shared_status("complete")
        assert assumed["todayCost"]["coveragePercent"] == 100
        assert assumed["billingAssumptions"]["creditPercent"] == 100
        bad = sessions / "bad.jsonl"
        bad.write_text("not json\n")
        assert check_shared_status("partial", "partial")["diagnostics"]["parseErrorCount"] == 1
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
        unavailable = check_shared_status("unavailable", "unavailable")
        assert "--" in unavailable["display"]["consumptionLabel"]
        bad.unlink()
        write_usage()
        env["FIXTURE_MODE"] = "failure"
        for value in [json.loads(run("status")), mcp("get_codex_status")]:
            save("failure", value)
            assert value["refresh"]["localUsage"]["status"] == "success"
            for source in ["quota", "credits", "resetCredits"]:
                freshness = value["refresh"][source]
                assert freshness["status"] == "failed", freshness
                assert not freshness.get("lastSuccessAtIso") and not freshness.get("dataAtIso")
                assert freshness.get("error")
        env["FIXTURE_MODE"] = "missing"
        for value in [json.loads(run("status")), mcp("get_codex_status")]:
            assert value["refresh"]["quota"]["status"] == "success"
            for source in ["credits", "resetCredits"]:
                assert value["refresh"][source]["status"] == "unavailable"
                assert not value["refresh"][source].get("lastSuccessAtIso")
            assert value["resetCredits"].get("availableCount") is None
        for mode in ["missing-percent", "invalid-numbers"]:
            env["FIXTURE_MODE"] = mode
            for value in [json.loads(run("status")), mcp("get_codex_status")]:
                save(mode, value)
                assert value["refresh"]["quota"]["status"] == "unavailable"
                assert value["display"]["primaryLabel"] == "W --"
                assert not value["refresh"]["quota"].get("lastSuccessAtIso")
                if mode == "invalid-numbers":
                    assert value["refresh"]["credits"]["status"] == "unavailable"
                    assert value["resetCredits"].get("availableCount") is None
                    assert value["refresh"]["resetCredits"]["status"] == "unavailable"
        env["FIXTURE_MODE"] = "hang"
        env["FIXTURE_PID_FILE"] = str(root / "child.pid")
        started = time.monotonic()
        timeout = json.loads(run("status"))
        assert 10 < time.monotonic() - started < 40
        assert timeout["refresh"]["quota"]["status"] == "failed"
        assert "Timed out" in timeout["refresh"]["quota"]["error"]
        assert timeout["refresh"]["localUsage"]["status"] == "success"
        pid = int((root / "child.pid").read_text())
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("Timed-out app-server process was left running")
        del env["FIXTURE_MODE"]
        recovered = json.loads(run("status"))
        assert recovered["refresh"]["quota"]["status"] == "success"
        assert not recovered["refresh"]["quota"].get("error")
        del env["CODEX_SESSIONS_DIR"]
        persistent = json.loads(run("status"))
        support = Path(env["CFFIXED_USER_HOME"]) / "Library/Application Support/Codex Rate Limits Bar"
        cache_file = support / "local-usage-cache.json"
        assert cache_file.exists(), "Persistent CLI cache must remain inside the isolated home"
        before = json.loads(cache_file.read_text())["cache"]["weeklyCostObservation"]
        for value in [json.loads(run("status")), mcp("get_codex_status")]:
            assert value["localUsage"]["totalTokens"] == persistent["localUsage"]["totalTokens"] == 1000
            for key in ["todayCost", "todayCredits", "billingAssumptions", "unpricedUsage"]:
                assert value["localUsage"][key] == persistent["localUsage"][key], key
        # Both copies survive a physical move to the archive, then a full rebuild.
        archive = profile / "archived_sessions"
        archive.mkdir()
        (sessions / "usage.jsonl").rename(archive / "renamed.jsonl")
        moved = json.loads(run("status"))
        rebuilt = json.loads(run("local-usage", "--rebuild"))
        for key in ["totalTokens", "inputTokens", "eventCount", "todayCost", "todayCredits"]:
            assert moved["localUsage"][key] == rebuilt[key] == persistent["localUsage"][key], key
        after = json.loads(cache_file.read_text())["cache"]["weeklyCostObservation"]
        for key in ["windowID", "startedAt", "baselineUsedPercent", "accountScopeKey", "timelineStartedAt"]:
            assert before[key] == after[key], (key, before[key], after[key])
        # Auth switches within one home must replace account observation, not daily usage.
        auth = json.loads((profile / "auth.json").read_text())
        auth["tokens"]["account_id"] = "fixture-account-b"
        (profile / "auth.json").write_text(json.dumps(auth))
        switched = json.loads(run("status"))
        assert switched["accountContext"]["accountKey"] != persistent["accountContext"]["accountKey"]
        assert switched["localUsage"]["weeklyQuotaCost"]["accountScopeKey"] != before["accountScopeKey"]
        assert switched["localUsage"]["totalTokens"] == 1000
        # Mutually incomplete archived/live copies must agree across processes.
        original = [json.loads(line) for line in (sessions / "renamed-copy.jsonl").read_text().splitlines()]
        instant = datetime.now(timezone.utc) - timedelta(seconds=5)
        def sample(total, second):
            value = json.loads(json.dumps(original[-1]))
            value["timestamp"] = (instant + timedelta(seconds=second)).isoformat().replace("+00:00", "Z")
            value["payload"]["info"]["total_token_usage"] = {"input_tokens": total, "total_tokens": total}
            return value
        for path, values, prefix in [(archive / "renamed.jsonl", [sample(100, 1), sample(300, 3)], "\n \t\r\n"),
                                      (sessions / "renamed-copy.jsonl", [sample(200, 2), sample(300, 3)], "")]:
            path.write_text(prefix + "".join(json.dumps(value) + "\n" for value in original[:-1] + values))
        observation = json.loads(cache_file.read_text())["cache"]["weeklyCostObservation"]
        values = [json.loads(run("status"))["localUsage"], mcp("get_codex_status")["localUsage"],
                  json.loads(run("local-usage", "--rebuild")), mcp("get_codex_local_usage")]
        for value in values:
            assert value["totalTokens"] == 300
            assert abs(value["todayCost"]["estimatedCostUSD"] - 0.0012) < 1e-12
            assert abs(value["todayCredits"]["estimatedCredits"] - 0.03) < 1e-12
            assert value["diagnostics"]["status"] == "complete"
        current = json.loads(cache_file.read_text())["cache"]["weeklyCostObservation"]
        for key in ["windowID", "startedAt", "baselineUsedPercent", "accountScopeKey", "timelineStartedAt"]:
            assert current[key] == observation[key]
    print("CLI/MCP integration passed: completeness, accounts, weekly evidence, pricing, independent freshness, missing fields, timeout cleanup, recovery, persistent restarts, archives, account switches and complementary copies.")


if __name__ == "__main__":
    main()
