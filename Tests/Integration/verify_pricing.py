"""Check read-only pricing diagnostics without network, account access or writes."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Support"))
from verification_support import isolated_environment, run_checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="codex-pricing-verification-") as directory:
        root = Path(directory)
        env = isolated_environment(root)
        profile = Path(env["CODEX_HOME"])
        # Any account read or write inside the fixture is blocked, even if a
        # future implementation accidentally introduces it into this command.
        policy = ('(version 1)(allow default)(deny network*)'
                  '(deny file-read* (subpath ' + json.dumps(str(profile)) + '))'
                  '(deny file-write* (subpath ' + json.dumps(str(root)) + '))')

        def tree():
            return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in root.rglob("*") if p.is_file()}

        def run(*options, fails=False):
            before = tree()
            command = ["/usr/bin/sandbox-exec", "-p", policy, str(binary), "pricing", *map(str, options)]
            kwargs = dict(env=env, capture_output=True, text=True, timeout=15)
            result = subprocess.run(command, **kwargs) if fails else run_checked(command, **kwargs)
            assert tree() == before, "Pricing commands must not change local files"
            if fails:
                assert result.returncode != 0 and result.stderr and not result.stdout
                return None
            return json.loads(result.stdout)

        builtin = run("--export-builtin")
        report = run("--health")
        assert report["schemaVersion"] == 1
        assert report["configurationStatus"] == "valid" and report["active"]["source"] == "builtin"
        assert not report["api"]["rateDifferences"] and not report["credits"]["coverageReviewRecommended"]
        assert len(report["builtinPolicyReviews"]) == 2
        assert all("priceExpiresOn" not in r for r in report["builtinPolicyReviews"])

        legacy = copy.deepcopy(builtin)
        legacy["api"]["version"] = "2026-10-06.1"
        legacy["api"]["models"]["gpt-5.5"]["cacheWriteInput"] = 6.25
        legacy["api"]["models"]["gpt-5.4"]["cacheWriteInput"] = 3.125
        legacy_file = root / "legacy-write-prices.json"
        legacy_file.write_text(json.dumps(legacy))
        report = run("--health", legacy_file)
        assert report["configurationStatus"] == "valid"
        differences = {row["model"]: row for row in report["api"]["rateDifferences"]}
        assert set(differences) == {"gpt-5.5", "gpt-5.4"}
        for model, old, corrected in [("gpt-5.5", 6.25, 5), ("gpt-5.4", 3.125, 2.5)]:
            assert differences[model]["activeRate"]["cacheWriteInput"] == old
            assert differences[model]["builtinRate"]["cacheWriteInput"] == corrected
        assert not report["credits"]["rateDifferences"]
        assert json.loads(legacy_file.read_text()) == legacy, "Health checks must preserve explicit custom prices"

        custom = copy.deepcopy(builtin)
        for kind in ("api", "credits"):
            del custom[kind]["models"]["gpt-6.1-sol"]
        custom["api"]["models"]["gpt-6-sol"]["input"] = 7
        del custom["credits"]["models"]["gpt-6-astra"]["serviceTiers"]["ultrafast"]
        custom["api"]["version"] = "intentional-contract"
        candidate = root / "candidate pricing.json"
        candidate.write_text(json.dumps(custom))
        report = run("--health", candidate)
        assert report["configurationStatus"] == "valid"
        assert report["active"]["source"] == "custom" and "configurationError" not in report["active"]
        assert report["api"]["missingModels"] == report["credits"]["missingModels"] == ["gpt-6.1-sol"]
        assert report["api"]["rateDifferences"][0]["activeRate"]["input"] == 7
        assert report["credits"]["missingServiceTiers"] == [{"model": "gpt-6-astra", "serviceTiers": ["ultrafast"]}]
        assert run()["source"] == "builtin", "Checking a candidate must not activate it"

        default_file = root / "home/Library/Application Support/Codex Rate Limits Bar/pricing.json"
        default_file.parent.mkdir(parents=True)
        default_file.write_bytes(candidate.read_bytes())
        assert run("--health")["active"]["configurationPath"] == str(default_file)
        assert run("--export") == custom
        env["CODEX_PRICING_FILE"] = str(candidate)
        assert run("--health")["active"]["configurationPath"] == str(candidate)
        assert run("--export") == custom, "Health diagnostics must preserve custom rates"

        candidate.write_text("{invalid")
        run("--health", candidate, fails=True)
        report = run("--health")
        assert report["configurationStatus"] == "fallback"
        assert report["active"]["source"] == "builtin" and report["active"]["configurationError"]
        assert run("--export") == builtin
        candidate.unlink()
        run("--health", candidate, fails=True)
        assert run("--health")["configurationStatus"] == "fallback"
        candidate.write_text(json.dumps(builtin))
        report = run("--health")
        assert report["configurationStatus"] == "valid" and report["active"]["source"] == "custom"
        assert not report["api"]["coverageReviewRecommended"]
        assert not report["credits"]["rateDifferences"]
        run("--health", candidate, "unexpected", fails=True)

    print("Pricing health verification passed: coverage, overrides, selection, fallback, recovery and read-only isolation.")


if __name__ == "__main__":
    main()
