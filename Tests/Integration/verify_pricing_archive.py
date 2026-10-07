"""Validate repository price archives offline; optionally check local Git provenance."""
import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

REPOSITORY = Path(__file__).resolve().parents[2]
SOURCE_PATH = "Sources/CodexRateLimitsCore/Resources/pricing.json"
ARCHIVE = REPOSITORY / "docs/pricing-archive"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def invalid_constant(value):
    raise ValueError(f"Non-finite JSON value: {value}")


def read_document(path):
    return json.loads(path.read_bytes(), object_pairs_hook=unique_object, parse_constant=invalid_constant)


def fields(value, names, label):
    require(isinstance(value, dict) and set(value) == set(names.split()), f"Invalid fields: {label}")


def valid_date(value, label):
    require(isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", value), f"Invalid date: {label}")
    return date.fromisoformat(value)


def strings(value, label):
    require(isinstance(value, list) and value and all(isinstance(x, str) and x.strip() for x in value),
            f"Expected nonempty strings: {label}")
    require(len(value) == len(set(value)), f"Duplicate values: {label}")


def local_path(root, relative):
    require(isinstance(relative, str) and relative and not relative.startswith("/")
            and "\\" not in relative and all(p not in ("", ".", "..") for p in relative.split("/")),
            f"Invalid relative path: {relative}")
    path = root
    for part in relative.split("/"):
        path = path / part
        require(not path.is_symlink(), f"Symlink is not an archive file: {relative}")
    require(path.is_file(), f"Missing archive file: {relative}")
    return path


def git_bytes(root, commit, path):
    result = subprocess.run(["git", "-C", str(root), "cat-file", "blob", f"{commit}:{path}"],
                            capture_output=True, timeout=15)
    require(result.returncode == 0, f"Git evidence unavailable: {commit}:{path}; fetch history and retry")
    return result.stdout


def validate_archive(archive=ARCHIVE, builtin=REPOSITORY / SOURCE_PATH, git_root=None):
    """Return (snapshot id, file path, full card) after read-only consistency checks.

    Swift's existing pricing --validate command checks rate semantics separately;
    this function checks the archive contract, not a second pricing schema.
    """
    archive, builtin = Path(archive).resolve(), Path(builtin)
    manifest = read_document(local_path(archive, "manifest.json"))
    fields(manifest, "schemaVersion scope sourcePath current snapshots", "manifest")
    require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1,
            "Unsupported archive schema")
    require(manifest["scope"] == "repository-configuration", "Archive must describe repository configurations")
    require(manifest["sourcePath"] == SOURCE_PATH, "Unexpected source path")
    require(isinstance(manifest["snapshots"], list) and manifest["snapshots"], "No archived snapshots")
    require(isinstance(manifest["current"], str), "Invalid current snapshot")
    seen_ids, seen_hashes, seen_commits, versions, expected_files, results = set(), set(), set(), {}, set(), []
    for entry in manifest["snapshots"]:
        fields(entry, "id file sha256 sourceCommit archivedOn repositoryEvidence api credits", "snapshot")
        identifier = entry["id"]
        require(isinstance(identifier, str) and re.fullmatch(r"api-[0-9.\-]+_credits-[0-9.\-]+", identifier),
                "Invalid snapshot id")
        require(identifier not in seen_ids, f"Duplicate snapshot: {identifier}")
        seen_ids.add(identifier)
        require(entry["file"] == f"cards/{identifier}.json", f"File/id mismatch: {identifier}")
        path = local_path(archive, entry["file"])
        expected_files.add(path.relative_to(archive).as_posix())
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        require(entry["sha256"] == digest, f"SHA-256 mismatch: {identifier}")
        require(digest not in seen_hashes, f"Duplicate card content: {identifier}")
        seen_hashes.add(digest)
        commit = entry["sourceCommit"]
        require(isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit), f"Invalid commit: {identifier}")
        require(commit not in seen_commits, f"Duplicate source commit: {identifier}")
        seen_commits.add(commit)
        archived = valid_date(entry["archivedOn"], identifier)
        strings(entry["repositoryEvidence"], "repository evidence")
        for evidence_path in entry["repositoryEvidence"]:
            require(evidence_path in ("docs/pricing.md", "TODO.md"), f"Unsupported evidence path: {evidence_path}")
        document = read_document(path)
        fields(document, "schemaVersion api credits", identifier)
        require(type(document["schemaVersion"]) is int and document["schemaVersion"] == 1,
                f"Unsupported price document: {identifier}")
        for kind in ("api", "credits"):
            metadata, card = entry[kind], document[kind]
            fields(metadata, "version verifiedAt effectiveFrom effectiveTo evidence", f"{identifier}/{kind}")
            require(isinstance(card, dict), f"Invalid card: {identifier}/{kind}")
            version = metadata["version"]
            require(isinstance(version, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}\.\d+", version),
                    f"Invalid version: {identifier}/{kind}")
            for key in ("version", "verifiedAt"):
                require(metadata[key] == card.get(key), f"{key} mismatch: {identifier}/{kind}")
            verified = valid_date(metadata["verifiedAt"], f"{identifier}/{kind}")
            require(verified <= archived, f"Verification after archival: {identifier}/{kind}")
            require(metadata["effectiveFrom"] is None and metadata["effectiveTo"] is None,
                    "Archive v1 records unknown effective periods; do not infer them from review dates")
            evidence = metadata["evidence"]
            fields(evidence, "kind reviewedOn sources summary", "evidence")
            require(evidence["kind"] in ("configuration-only", "recorded-review"), "Invalid evidence kind")
            if evidence["kind"] == "recorded-review":
                require(valid_date(evidence["reviewedOn"], "reviewedOn") <= archived,
                        "Review after archival")
            else:
                require(evidence["reviewedOn"] is None, "Configuration-only evidence cannot claim a review date")
            require(isinstance(evidence["summary"], str) and evidence["summary"].strip(), "Missing evidence summary")
            strings(evidence["sources"], "sources")
            require(evidence["sources"] == card.get("sources"), f"Sources mismatch: {identifier}/{kind}")
            for source in evidence["sources"]:
                url = urlsplit(source)
                require(url.scheme == "https" and url.hostname and not url.username and not url.password,
                        f"Invalid source URL: {identifier}/{kind}")
            # A repeated product version must retain its entire card, including metadata.
            key = (kind, version)
            if key in versions:
                require(versions[key] == card, f"Conflicting {kind} version: {version}")
            versions[key] = card
        expected_id = f"api-{entry['api']['version']}_credits-{entry['credits']['version']}"
        require(identifier == expected_id, f"Version/id mismatch: {identifier}")
        if git_root is not None:
            require(git_bytes(git_root, commit, SOURCE_PATH) == path.read_bytes(), f"Git content mismatch: {identifier}")
            for evidence_path in entry["repositoryEvidence"]:
                git_bytes(git_root, commit, evidence_path)
        results.append((identifier, path, document))
    actual_files = set()
    for path in (archive / "cards").rglob("*"):
        require(not path.is_symlink(), f"Symlink in card directory: {path.name}")
        if path.is_file():
            actual_files.add(path.relative_to(archive).as_posix())
    require(actual_files == expected_files, "Card inventory differs from manifest (unlisted or missing file)")
    require(manifest["current"] in seen_ids, "Current snapshot is missing")
    current = next(path for identifier, path, _ in results if identifier == manifest["current"])
    require(current.read_bytes() == builtin.read_bytes(), "Current archive differs from bundled source bytes")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=ARCHIVE)
    parser.add_argument("--builtin", type=Path, default=REPOSITORY / SOURCE_PATH)
    parser.add_argument("--git-root", type=Path, help="Also verify committed bytes in a local full-history checkout")
    args = parser.parse_args()
    try:
        results = validate_archive(args.archive, args.builtin, args.git_root)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Pricing archive verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Pricing archive verification passed: {len(results)} snapshots, hashes, evidence, versions and current resource"
          + ("; Git provenance checked." if args.git_root else "; Git provenance not checked."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
