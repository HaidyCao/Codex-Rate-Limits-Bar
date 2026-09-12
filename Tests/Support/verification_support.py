"""macOS verification isolation: fake Foundation home, preferences, and credentials."""
import os
from pathlib import Path
import plistlib
import subprocess


def isolated_environment(root):
    root = Path(root).resolve()
    home = root / "home"
    profile = home / ".codex"
    sessions = profile / "sessions"
    sessions.mkdir(parents=True, exist_ok=True)
    preferences = home / "Library/Preferences"
    preferences.mkdir(parents=True, exist_ok=True)
    with (preferences / ".GlobalPreferences.plist").open("wb") as handle:
        plistlib.dump({"AppleLanguages": ["en-US"], "AppleLocale": "en_US"}, handle)
    deny_codex = root / "unexpected-codex"
    deny_codex.write_text("#!/bin/sh\necho 'Unexpected official request in isolated verification' >&2\nexit 97\n")
    deny_codex.chmod(0o700)
    # HOME belongs to the caller. CFFIXED_USER_HOME redirects Foundation's
    # credentials, application support, preferences and logs for child processes.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("CODEX_", "FIXTURE_")) and key not in {"CFFIXED_USER_HOME", "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID"}}
    env.update(CFFIXED_USER_HOME=str(home), CODEX_HOME=str(profile),
               CODEX_SESSIONS_DIR=str(sessions), CODEX_BIN=str(deny_codex), TZ="UTC")
    return env


def offline_command(command):
    return ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", *map(str, command)]


def run_checked(command, **kwargs):
    """Include subprocess stderr in a failed verification rather than hiding it."""
    result = subprocess.run(command, **kwargs)
    if result.returncode:
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr)
        raise subprocess.CalledProcessError(result.returncode, command)
    return result
