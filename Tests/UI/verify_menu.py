"""Compile the actual AppKit views with a verification entry point, then render fixtures."""
import argparse
from pathlib import Path
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Support"))
from verification_support import isolated_environment, offline_command, run_checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="release")
    parser.add_argument("--artifacts", type=Path, default=Path(".build/verification"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    artifacts = (repo / args.artifacts).resolve()
    build = Path(run_checked(["swift", "build", "-c", args.config, "--show-bin-path"], cwd=repo,
                             text=True, capture_output=True).stdout.strip())
    executable = artifacts / "VerifyMenu"
    objects = sorted((build / "CodexRateLimitsCore.build").glob("*.swift.o"))
    if not objects:
        raise SystemExit("Core objects missing; run make build first")
    run_checked(["swiftc", "-swift-version", "6", "-parse-as-library",
                 "-I", build / "Modules", *objects, repo / "Sources/CodexRateLimitsBar/MenuBarApp.swift",
                 repo / "Tests/UI/VerifyMenu.swift", "-o", executable])
    with tempfile.TemporaryDirectory(prefix="codex-menu-verification-") as directory:
        run_checked(offline_command([executable, artifacts / "fixtures", artifacts / "menu"]),
                    env=isolated_environment(directory))


if __name__ == "__main__":
    main()
