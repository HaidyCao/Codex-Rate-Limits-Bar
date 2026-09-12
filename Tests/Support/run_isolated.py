"""Run a command without real Codex credentials, user state, or network access."""
from pathlib import Path
import sys
import tempfile
from verification_support import isolated_environment, offline_command, run_checked

if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: run_isolated.py COMMAND [ARG ...]")
    with tempfile.TemporaryDirectory(prefix="codex-verification-") as directory:
        env = isolated_environment(Path(directory))
        command = sys.argv[1:]
        if Path(command[0]).name == "swift" and command[1:2] in (["test"], ["build"]):
            # SwiftPM's nested manifest sandbox cannot run inside sandbox-exec.
            # The outer network-denial sandbox remains active for all children.
            command.insert(2, "--disable-sandbox")
        run_checked(offline_command(command), env=env)
