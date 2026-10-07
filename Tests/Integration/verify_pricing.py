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
from verify_pricing_archive import ARCHIVE, REPOSITORY, SOURCE_PATH, read_document, validate_archive


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
                  '(deny file-write* (subpath ' + json.dumps(str(ARCHIVE)) + '))'
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
        archived = validate_archive()
        for identifier, path, document in archived:
            metadata = run("--validate", path)
            for kind in ("api", "credits"):
                assert metadata[kind]["version"] == document[kind]["version"], identifier
        assert builtin == read_document(REPOSITORY / SOURCE_PATH), "Built app must match the current archived resource"

        # Capture a review before its commit exists, then use the native parser
        # without selecting the candidate as the user's active configuration.
        content_archive = root / "candidate-archive"
        manifest = read_document(ARCHIVE / "manifest.json")
        entry = copy.deepcopy(next(e for e in manifest["snapshots"] if e["id"] == manifest["current"]))
        entry["sourceCommit"] = None
        entry["evidenceFiles"] = {}
        card_file = content_archive / entry["file"]
        card_file.parent.mkdir(parents=True)
        card_file.write_bytes((REPOSITORY / SOURCE_PATH).read_bytes())
        for source in entry["repositoryEvidence"]:
            relative = f"evidence/{entry['id']}/{source.replace('/', '__')}.txt"
            evidence_file = content_archive / relative
            evidence_file.parent.mkdir(parents=True, exist_ok=True)
            evidence_file.write_bytes((REPOSITORY / source).read_bytes())
            entry["evidenceFiles"][source] = {"file": relative, "sha256": hashlib.sha256(evidence_file.read_bytes()).hexdigest()}
        manifest.update(schemaVersion=2, snapshots=[entry])
        (content_archive / "manifest.json").write_text(json.dumps(manifest))
        assert len(validate_archive(content_archive, REPOSITORY / SOURCE_PATH)) == 1
        metadata = run("--validate", card_file)
        for kind in ("api", "credits"):
            assert metadata[kind]["version"] == builtin[kind]["version"]
        assert run("--export") == builtin, "Content archive validation must not activate a custom card"

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

        capped = copy.deepcopy(builtin)
        capped["api"]["version"] = "2026-10-06.2"
        del capped["api"]["models"]["gpt-5.6-cyber"]["contextTier"]
        capped["api"]["models"]["gpt-5.6-cyber"]["maximumInputTokens"] = 272_000
        capped_file = root / "capped-cyber.json"
        capped_file.write_text(json.dumps(capped))
        report = run("--health", capped_file)
        assert report["configurationStatus"] == "valid"
        differences = {row["model"]: row for row in report["api"]["rateDifferences"]}
        assert set(differences) == {"gpt-5.6-cyber", "gpt-daybreak-red-latest"}
        for row in differences.values():
            assert row["activeRate"]["maximumInputTokens"] == 272_000
            assert row["builtinRate"]["contextTier"] == {
                "threshold": 272_000, "inputMultiplier": 2, "outputMultiplier": 1.5}
        assert not report["credits"]["rateDifferences"]
        assert json.loads(capped_file.read_text()) == capped, "Health checks must preserve a custom context cap"
        assert run("--health")["active"]["source"] == "builtin", "Checking a candidate must not activate it"

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

    print(f"Pricing health verification passed: {len(archived)} archived cards, a pre-commit content snapshot, coverage, overrides, selection, fallback, recovery and read-only isolation.")


if __name__ == "__main__":
    main()
