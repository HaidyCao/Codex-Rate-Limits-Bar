"""Exercise plugin installation and rollback with an isolated, stateful fake Codex CLI."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Support"))
from verification_support import isolated_environment, offline_command

PLUGIN = "codex-usage-monitor"
FAKE_CODEX = r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
home = Path(os.environ["CFFIXED_USER_HOME"])
profile = Path(os.environ["CODEX_HOME"])
assert profile == Path(os.environ["FIXTURE_PROFILE"])
assert Path.cwd().resolve() == home.resolve()
args = sys.argv[1:]
assert args[0] == "plugin"
command = args[1]
log = Path(os.environ["FIXTURE_COMMANDS"])
with log.open("a") as f: f.write(command + "\n")
mode = os.environ["FIXTURE_MODE"]
cache = profile / "plugins/cache/personal/codex-usage-monitor"
config = profile / "config.toml"
if command == "list":
    if mode == "list-failure":
        print("fixture list failed", file=sys.stderr)
        sys.exit(3)
    print(json.dumps({"installed": [] if mode.startswith("first-") else [{"pluginId":"codex-usage-monitor@personal"}]}))
elif command == "remove":
    assert args[2] == "codex-usage-monitor@personal"
    if cache.exists(): shutil.rmtree(cache)
    config.write_text(config.read_text() + "# partial remove\n")
    if mode == "remove-failure":
        print("fixture remove failed", file=sys.stderr)
        sys.exit(4)
    print("{}")
elif command == "add":
    assert args[2] == "codex-usage-monitor@personal"
    source = home / "plugins/codex-usage-monitor"
    manifest = json.loads((source / ".codex-plugin/plugin.json").read_text())
    marketplace = json.loads((home / ".agents/plugins/marketplace.json").read_text())
    assert manifest["version"].startswith("0.4.0+codex.")
    assert marketplace["name"] == "personal"
    config.parent.mkdir(parents=True, exist_ok=True)
    previous = config.read_text() if config.exists() else ""
    config.write_text(previous + '[plugins."codex-usage-monitor@personal"]\nenabled = true\n')
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "partial.txt").write_text("new cached plugin")
    if mode in {"add-failure", "first-failure"}:
        print("fixture add failed: 安装中断 🚫", file=sys.stderr)
        sys.exit(5)
    print("{}")
else:
    raise AssertionError(args)
'''


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def snapshot(paths):
    values = {}
    for index, path in enumerate(paths):
        if not path.exists():
            values[str(index)] = None
        elif path.is_dir():
            values[str(index)] = {str(f.relative_to(path)): (f.read_bytes(), f.stat().st_mode & 0o777)
                                  for f in path.rglob("*") if f.is_file()}
        else:
            values[str(index)] = (path.read_bytes(), path.stat().st_mode & 0o777)
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    bundled = Path(__file__).resolve().parents[2] / "plugins" / PLUGIN
    results = []
    for mode in ["success", "first-success", "add-failure", "first-failure", "remove-failure", "list-failure", "bad-marketplace"]:
        with tempfile.TemporaryDirectory(prefix="codex-plugin-verification-") as temporary:
            root = Path(temporary)
            env = isolated_environment(root)
            home = Path(env["CFFIXED_USER_HOME"])
            profile = root / "selected-profile"
            source = root / "source"
            shutil.copytree(bundled, source)
            installed = home / "plugins" / PLUGIN
            marketplace = home / ".agents/plugins/marketplace.json"
            config = profile / "config.toml"
            cache = profile / "plugins/cache/personal" / PLUGIN
            unrelated = profile / "plugins/cache/personal/other/keep.txt"
            default_config = home / ".codex/config.toml"
            write(unrelated, "unrelated plugin")
            write(default_config, "# default profile must stay untouched\n")
            if not mode.startswith("first-"):
                write(installed / "old.txt", "old plugin")
                write(cache / "old/version.txt", "old cached plugin")
                write(config, '# preserve comments\n[plugins."other@personal"]\nenabled = false\n')
                config.chmod(0o600)
                write(marketplace, '{"name":"personal","plugins":[{"name":"other","source":{"source":"local","path":"./other"}}]}\n')
                marketplace.chmod(0o640)
            if mode == "bad-marketplace":
                write(marketplace, "{broken JSON")
            protected = [installed, marketplace, config, cache, unrelated, default_config, source]
            before = snapshot(protected)
            fake = root / "fake-codex"
            fake.write_text(FAKE_CODEX)
            fake.chmod(0o700)
            commands = root / "commands.txt"
            env.update(CODEX_BIN=str(fake), CODEX_HOME=str(profile), FIXTURE_PROFILE=str(profile),
                       FIXTURE_MODE=mode, FIXTURE_COMMANDS=str(commands))
            result = subprocess.run(offline_command([binary, "install-plugin", "--source", source]), env=env,
                                    capture_output=True, text=True, timeout=20)
            calls = commands.read_text().splitlines() if commands.exists() else []
            if mode in {"success", "first-success"}:
                assert result.returncode == 0, result.stderr
                assert (installed / ".mcp.json").exists()
                assert calls == (["list", "add"] if mode == "first-success" else ["list", "remove", "add"]), calls
                for index in [4, 5, 6]:
                    assert snapshot(protected)[str(index)] == before[str(index)]
                if mode == "success":
                    assert json.loads(marketplace.read_text())["plugins"][0]["name"] == "other"
                    assert marketplace.stat().st_mode & 0o777 == 0o640
                    assert '[plugins."other@personal"]\nenabled = false' in config.read_text()
            else:
                assert result.returncode != 0, mode
                assert snapshot(protected) == before, (mode, result.stderr)
                assert calls == {"add-failure": ["list", "remove", "add"], "first-failure": ["list", "add"],
                                 "remove-failure": ["list", "remove"], "list-failure": ["list"],
                                 "bad-marketplace": []}[mode], calls
                if "add" in calls:
                    assert "安装中断 🚫" in result.stderr
                if calls:
                    assert "restored" in result.stderr
            assert not list((home / "plugins").glob(".codex-usage-monitor-install-*"))
            results.append({"mode": mode, "commands": calls, "passed": True})
    args.artifacts.parent.mkdir(parents=True, exist_ok=True)
    args.artifacts.write_text(json.dumps(results, indent=2) + "\n")
    print("Plugin installation verification passed: 7 isolated cases; default profile and unrelated files preserved.")


if __name__ == "__main__":
    main()
