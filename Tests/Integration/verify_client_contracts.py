"""Replay observed projections and synthetic client/account contracts offline."""
import argparse
import base64
import copy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Support"))
from verification_support import isolated_environment, offline_command, run_checked


def validate_projection(document):
    """Keep committed rollout fixtures limited to explicitly reviewed fields."""
    counters = {"input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens",
                "reasoning_output_tokens", "total_tokens"}
    for file in document["files"]:
        assert set(file) == {"name", "events"}
        for event in file["events"]:
            assert set(event) == {"type", "timestamp", "payload"}
            payload = event["payload"]
            if event["type"] == "session_meta":
                assert set(payload) <= {"id", "cli_version", "source"}
                if isinstance(payload.get("source"), dict):
                    assert set(payload["source"]) == {"subagent"}
                    assert set(payload["source"]["subagent"]) == {"thread_spawn"}
                    assert set(payload["source"]["subagent"]["thread_spawn"]) == {"parent_thread_id", "depth"}
            elif event["type"] == "turn_context":
                assert set(payload) <= {"model", "service_tier"}
            else:
                assert event["type"] == "event_msg"
                if payload["type"] == "thread_settings_applied":
                    assert set(payload) <= {"type", "model", "service_tier"}
                else:
                    assert payload["type"] == "token_count" and set(payload) == {"type", "info"}
                    info = payload["info"]
                    assert set(info) <= {"total_token_usage", "last_token_usage", "model_context_window"}
                    for key in ("total_token_usage", "last_token_usage"):
                        assert set(info[key]) <= counters
                        assert all(type(v) is int and v >= 0 for v in info[key].values())


def comparable(value, key=""):
    if isinstance(value, dict):
        return {k: comparable(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [comparable(v) for v in value]
    if key in ("estimatedCostUSD", "estimatedCredits", "observedCostUSD") and isinstance(value, float):
        return round(value, 12)
    return value


def assert_daily_equal(actual, expected):
    for key in ("totalTokens", "inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens",
                "reasoningOutputTokens", "todayCost", "todayCredits", "billingAssumptions", "unpricedUsage", "pricing"):
        assert comparable(actual.get(key)) == comparable(expected.get(key)), (key, actual.get(key), expected.get(key))
    assert actual["diagnostics"]["status"] == expected["diagnostics"]["status"] == "complete"
    display = lambda item: {k: v for k, v in item["display"].items() if k != "weeklyQuotaCostLabel"}
    left, right = display(actual), display(expected)
    assert left == right, {k: (left.get(k), right.get(k)) for k in left.keys() | right.keys() if left.get(k) != right.get(k)}


def synthetic_cache_write_contract():
    """Construct old-model write cases; these are not observed billing records."""
    document = {"provenance": {"kind": "synthetic-contract", "reviewedOn": "2026-10-06"}, "files": []}
    for model in ("gpt-5.5", "gpt-5.4", "gpt-6.1-sol"):
        def event(kind, payload):
            return {"type": kind, "timestamp": "2026-10-06T12:00:00Z", "payload": payload}
        usage = {"input_tokens": 100000, "cached_input_tokens": 80000 if model == "gpt-6.1-sol" else 40000,
                 "cache_write_input_tokens": 0 if model == "gpt-6.1-sol" else 20000,
                 "output_tokens": 5000, "reasoning_output_tokens": 4000, "total_tokens": 105000}
        events = [event("session_meta", {"id": "write-contract-" + model}),
                  event("turn_context", {"model": model, "service_tier": "standard"})]
        for count in (1, 2):
            events.append(event("event_msg", {"type": "token_count", "info": {
                "total_token_usage": {k: v * count for k, v in usage.items()}, "last_token_usage": usage}}))
        document["files"].append({"name": model, "events": events})
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    fixtures = Path(__file__).resolve().parents[1] / "Fixtures/client-contracts"
    observed = json.loads((fixtures / "observed-rollouts.json").read_text())
    synthetic = json.loads((fixtures / "synthetic-modes.json").read_text())
    cache_writes = synthetic_cache_write_contract()
    for document in (observed, synthetic, cache_writes): validate_projection(document)
    accounts = json.loads((fixtures / "official-accounts.json").read_text())["cases"]
    artifacts = args.artifacts.resolve() if args.artifacts else None
    if artifacts:
        artifacts.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="codex-client-contracts-") as directory:
        root = Path(directory)
        env = isolated_environment(root)
        # Enable actual disk-cache loading across CLI/MCP processes. Both
        # discovered homes are inside the isolated Foundation home.
        env.pop("CODEX_SESSIONS_DIR")
        profile = Path(env["CODEX_HOME"])
        sessions = profile / "sessions"
        response_file = root / "responses.json"
        fake = root / "fake-codex"
        fake.write_text('''#!/usr/bin/env python3
import json, os, sys
fixture = json.load(open(os.environ["CONTRACT_RESPONSE_FILE"]))
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    if method == "account/rateLimits/read" and fixture.get("rateLimitsError"):
        result = {"id": request["id"], "error": {"code": -1, "message": fixture["rateLimitsError"]}}
    else:
        value = fixture["accountResponse"] if method == "account/read" else fixture["rateLimitsResponse"] if method == "account/rateLimits/read" else {}
        result = {"id": request["id"], "result": value}
    print(json.dumps(result), flush=True)
''')
        fake.chmod(0o700)
        env.update(CODEX_BIN=str(fake), CONTRACT_RESPONSE_FILE=str(response_file))
        # All replayed records are near local noon, safely before now and after
        # the previous day, including when verification runs at UTC midnight.
        now = datetime.now(timezone.utc)
        offset = 12 - now.hour
        env["TZ"] = f"Etc/GMT{-offset:+d}" if offset else "Etc/GMT"
        base = now - timedelta(minutes=10)
        reset = int((now + timedelta(days=2)).timestamp())

        def run(*args, input=None):
            return json.loads(run_checked(offline_command([binary, *args, "-AppleLanguages", "(en-US)"]),
                env=env, input=input, capture_output=True, text=True, timeout=45).stdout)

        def mcp(name):
            requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "contracts", "version": "1"}}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": {}}}]
            output = run_checked(offline_command([binary, "mcp", "-AppleLanguages", "(en-US)"]), env=env,
                input="".join(json.dumps(v) + "\n" for v in requests), capture_output=True, text=True, timeout=45).stdout
            result = next(json.loads(line)["result"] for line in output.splitlines() if json.loads(line).get("id") == 2)
            assert not result.get("isError"), result
            return json.loads(result["content"][0]["text"])

        def select_account(fixture):
            selected = copy.deepcopy(fixture)
            def replace_reset(value):
                if isinstance(value, dict):
                    for k, v in value.items():
                        if k == "resetsAt": value[k] = reset
                        else: replace_reset(v)
            replace_reset(selected)
            response_file.write_text(json.dumps(selected))
            if fixture["accountResponse"]["account"]["type"] == "apiKey":
                auth = {"OPENAI_API_KEY": "fixture-key"}
            else:
                claims = base64.urlsafe_b64encode(json.dumps({"sub": "fixture-user", "email": "fixture@example.invalid"}).encode()).decode().rstrip("=")
                auth = {"tokens": {"id_token": f"h.{claims}.s", "access_token": "fixture-access", "account_id": "fixture-account"}}
            (profile / "auth.json").write_text(json.dumps(auth))

        def install(document, prefix=False, append=False):
            if not append:
                for path in sessions.glob("*.jsonl"): path.unlink()
            for file in document["files"]:
                events = copy.deepcopy(file["events"])
                # Preserve order and equal timestamps across duplicate copies.
                for i, event in enumerate(events):
                    event["timestamp"] = (base + timedelta(seconds=i)).isoformat().replace("+00:00", "Z")
                events = events[-1:] if append else events[:-1] if prefix else events
                content = "".join(json.dumps(v) + "\n" for v in events)
                for suffix in ("", "-copy"):
                    with (sessions / (file["name"] + suffix + ".jsonl")).open("a" if append else "w") as handle:
                        handle.write(content)

        def save(name, value):
            if artifacts: (artifacts / (name + ".json")).write_text(json.dumps(value, indent=2))

        for document, name, prefix_tokens, tokens, api, credits, missing, unpriced_api, unpriced_credits in [
            (cache_writes, "contract-cache-writes", 315000, 630000, 1.606, 4.9, 0, 0, 420000),
            (observed, "contract-observed", 102644, 245087, 0.30183598, 7.5458995, 245087, 0, 0),
            (synthetic, "contract-modes", 525000, 735000, 0.9353, 92.415, 105000, 105000, 210000)
        ]:
            # Distinct corpora get distinct homes/caches. Removing source logs
            # from a live cache correctly retains their prior totals as partial.
            env = isolated_environment(root / name)
            env.pop("CODEX_SESSIONS_DIR")
            env.update(CODEX_BIN=str(fake), CONTRACT_RESPONSE_FILE=str(response_file),
                       TZ=f"Etc/GMT{-offset:+d}" if offset else "Etc/GMT")
            profile = Path(env["CODEX_HOME"])
            sessions = profile / "sessions"
            select_account(accounts[0])
            install(document, prefix=True)
            prefix = run("local-usage", "--rebuild")
            assert prefix["totalTokens"] == prefix_tokens, (name, prefix["totalTokens"], prefix["diagnostics"])
            install(document, append=True)
            incremental = run("local-usage")
            assert incremental["totalTokens"] == tokens
            assert abs(incremental["todayCost"]["estimatedCostUSD"] - api) < 1e-12
            assert abs(incremental["todayCredits"]["estimatedCredits"] - credits) < 1e-12
            assert incremental["todayCost"]["unpricedTokens"] == unpriced_api
            assert incremental["todayCredits"]["unpricedTokens"] == unpriced_credits
            assert incremental["billingAssumptions"]["missingServiceTierTokens"] == missing
            assert all(len(f["sourceFiles"]) == 2 for f in incremental["topFiles"])
            cache = Path(env["CFFIXED_USER_HOME"]) / "Library/Application Support/Codex Rate Limits Bar/local-usage-cache.json"
            assert cache.exists(), "The cross-process test requires a real isolated cache"
            before = cache.read_bytes()
            assert_daily_equal(run("local-usage"), incremental)
            assert cache.read_bytes() == before, "Unchanged restart must reuse the cache"
            for value in [mcp("get_codex_local_usage"), run("local-usage", "--rebuild")]:
                assert_daily_equal(value, incremental)
            status = run("status")
            shared = mcp("get_codex_status")
            for value in [status, shared]: assert_daily_equal(value["localUsage"], incremental)
            assert status["rateLimits"]["credits"]["balance"] == "12.5"
            assert status["localUsage"]["weeklyQuotaCost"]["valuation"]["effectiveIntervalCount"] == 0
            save(name, status)

        baseline = run("local-usage")
        for fixture in accounts:
            select_account(fixture)
            status = run("status")
            shared = mcp("get_codex_status")
            official = mcp("get_codex_rate_limits")
            for value in (status, shared, official):
                selected = value.get("rateLimitsByLimitId", {}).get("codex", value.get("rateLimits")) or {}
                weekly = next((w for w in (selected.get("primary"), selected.get("secondary"))
                               if w and w.get("windowDurationMins") == 10080), None)
                expected = fixture["expected"]
                assert (weekly or {}).get("remainingPercent") == expected["weeklyRemaining"]
                assert (selected.get("credits") or {}).get("balance") == expected["balance"]
                assert value["display"].get("primaryRemainingPercent") == expected["weeklyRemaining"]
                assert value["refresh"]["quota"]["status"] == ("success" if weekly else "unavailable")
                assert value["refresh"]["credits"]["status"] == ("success" if expected["balance"] is not None else "unavailable")
            for value in (status, shared):
                assert_daily_equal(value["localUsage"], baseline)
                if fixture["expected"]["weeklyRemaining"] is None:
                    assert value["localUsage"].get("weeklyQuotaCost") is None
            save("contract-" + fixture["name"], status)

        failed_api = copy.deepcopy(next(c for c in accounts if c["name"] == "api-key"))
        failed_api["rateLimitsError"] = "Rate limits unavailable for this API-key fixture"
        select_account(failed_api)
        status = run("status")
        for value in (status, mcp("get_codex_status")):
            assert value["rateLimitError"]
            assert value["refresh"]["quota"]["status"] == "failed"
            assert_daily_equal(value["localUsage"], baseline)
        save("contract-api-key-error", status)

    print("Client contracts passed: observed counters, synthetic modes, copies, persistent restarts/rebuilds, CLI/MCP and 7 account shapes.")


if __name__ == "__main__":
    main()
