"""pgvitals CLI entry point.

Installed as the ``pgvitals`` command by pyproject.toml.
Delegates to runner/run_diagnostics.py, resolving SQL files from:
  1. pgvitals/sql/  — bundled with the installed package
  2. <repo_root>/sql/ — development / cloned repo layout
  3. --sql-dir <path> — explicit override
  4. pgvitals init   — downloads SQL files to ~/.pgvitals/sql/
"""
from __future__ import annotations

import sys
from pathlib import Path


# ── Resolve SQL directory ──────────────────────────────────────────────────────

def _default_sql_dir() -> Path | None:
    """Return the best sql/ directory without raising — None if not found."""
    # 1. Bundled alongside this file (installed package)
    pkg_sql = Path(__file__).parent / "sql"
    if pkg_sql.is_dir() and any(pkg_sql.glob("*.sql")):
        return pkg_sql

    # 2. Development layout: <repo_root>/sql/
    dev_sql = Path(__file__).parent.parent / "sql"
    if dev_sql.is_dir() and any(dev_sql.glob("*.sql")):
        return dev_sql

    # 3. User-installed via `pgvitals init`
    home_sql = Path.home() / ".pgvitals" / "sql"
    if home_sql.is_dir() and any(home_sql.glob("*.sql")):
        return home_sql

    return None


# ── init sub-command ───────────────────────────────────────────────────────────

def _init() -> int:
    """Download SQL files from GitHub to ~/.pgvitals/sql/."""
    import json
    import urllib.request

    GITHUB_API = "https://api.github.com/repos/pgvitals/pgvitals/contents/sql"
    RAW_BASE   = "https://raw.githubusercontent.com/pgvitals/pgvitals/master/sql"

    dest = Path.home() / ".pgvitals" / "sql"
    dest.mkdir(parents=True, exist_ok=True)

    print(f"Downloading pgvitals SQL files to {dest} ...")
    try:
        with urllib.request.urlopen(GITHUB_API, timeout=15) as resp:
            files = json.loads(resp.read())
    except Exception as exc:
        print(f"Error: could not fetch file list from GitHub — {exc}", file=sys.stderr)
        return 1

    count = 0
    for entry in files:
        name = entry.get("name", "")
        if not name.endswith(".sql"):
            continue
        url = f"{RAW_BASE}/{name}"
        try:
            with urllib.request.urlopen(url, timeout=15) as resp:
                (dest / name).write_bytes(resp.read())
            print(f"  ✓  {name}")
            count += 1
        except Exception as exc:
            print(f"  ✗  {name}  ({exc})", file=sys.stderr)

    if count == 0:
        print("No SQL files downloaded — check your network.", file=sys.stderr)
        return 1

    print(f"\n{count} SQL files installed.")
    print(f"\nRun the diagnostic suite:")
    print(f"  pgvitals --host localhost --database mydb --user postgres")
    print(f"\nOr run the health score only:")
    print(f"  psql -d mydb -f {dest.parent.parent / 'health_score.sql'}")
    return 0


# ── main ───────────────────────────────────────────────────────────────────────

def main() -> int:
    args = sys.argv[1:]

    # Handle `pgvitals init` before the runner parses args
    if args and args[0] == "init":
        return _init()

    if args and args[0] in ("-h", "--help") and len(args) == 1:
        # Let the runner print its full help
        pass

    # Inject --sql-dir if the runner won't find it on its own
    if "--sql-dir" not in args:
        sql_dir = _default_sql_dir()
        if sql_dir:
            sys.argv.extend(["--sql-dir", str(sql_dir)])
        else:
            print(
                "pgvitals: SQL files not found.\n"
                "Run `pgvitals init` to download them, or pass --sql-dir <path>.",
                file=sys.stderr,
            )
            return 1

    # Locate the runner script (works in both installed and dev layouts)
    candidates = [
        Path(__file__).parent.parent / "runner" / "run_diagnostics.py",  # dev
        Path(__file__).parent / "_runner.py",                             # bundled
    ]
    runner_path = next((p for p in candidates if p.exists()), None)
    if runner_path is None:
        print(
            "pgvitals: cannot locate the runner script.\n"
            "Try reinstalling: pip install --force-reinstall pgvitals",
            file=sys.stderr,
        )
        return 1

    import importlib.util
    spec = importlib.util.spec_from_file_location("_pgvitals_runner", runner_path)
    mod  = importlib.util.module_from_spec(spec)   # type: ignore[arg-type]
    spec.loader.exec_module(mod)                   # type: ignore[union-attr]
    return mod.main()


if __name__ == "__main__":
    sys.exit(main())
