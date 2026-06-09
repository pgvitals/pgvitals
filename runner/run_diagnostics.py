#!/usr/bin/env python3
"""
pgvitals diagnostic runner
===========================
Execute all (or selected) pgvitals diagnostic SQL sections against a live
PostgreSQL database and generate a Markdown analysis report.

Usage
-----
    # Run with a config file (default: pgvitals.conf)
    python run_diagnostics.py

    # Use a named connection profile
    python run_diagnostics.py --profile staging

    # Override connection via CLI
    python run_diagnostics.py --host db.example.com --user monitor --database prod

    # Run specific sections only
    python run_diagnostics.py --sections 01,03,19,26,32

    # Skip specific sections
    python run_diagnostics.py --skip 05,36

    # Set output path
    python run_diagnostics.py --output ./my_report.md

Environment Variables
---------------------
    PGPASSWORD   - Password (overrides config file)
    PGHOST       - Host (overrides config file)
    PGPORT       - Port (overrides config file)
    PGUSER       - User (overrides config file)
    PGDATABASE   - Database (overrides config file)

Requirements
------------
    - Python 3.8+
    - psql (PostgreSQL client) on PATH or configured in pgvitals.conf
    - No third-party Python dependencies
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ── Fix Windows console UTF-8 ──────────────────────────────────────
if sys.platform == "win32":
    sys.stdout = io.TextIOWrapper(
        sys.stdout.buffer, encoding="utf-8", errors="replace"
    )
    sys.stderr = io.TextIOWrapper(
        sys.stderr.buffer, encoding="utf-8", errors="replace"
    )

# ── Constants ───────────────────────────────────────────────────────
SCRIPT_DIR  = Path(__file__).resolve().parent
DEFAULT_CFG = SCRIPT_DIR / "pgvitals.conf"
DEFAULT_SQL = SCRIPT_DIR.parent / "sql"

# Section metadata for smarter analysis
SECTION_META: dict[str, dict[str, str]] = {
    "00": {"area": "Prerequisites",    "risk": "info"},
    "01": {"area": "Query Behavior",   "risk": "high"},
    "02": {"area": "Query Behavior",   "risk": "medium"},
    "03": {"area": "Query Behavior",   "risk": "medium"},
    "04": {"area": "Query Behavior",   "risk": "medium"},
    "05": {"area": "Query Behavior",   "risk": "low"},
    "06": {"area": "Index Health",     "risk": "medium"},
    "07": {"area": "Index Health",     "risk": "medium"},
    "08": {"area": "Index Health",     "risk": "high"},
    "09": {"area": "Index Health",     "risk": "medium"},
    "10": {"area": "Index Health",     "risk": "medium"},
    "11": {"area": "Tables & Storage", "risk": "medium"},
    "12": {"area": "Tables & Storage", "risk": "low"},
    "13": {"area": "Tables & Storage", "risk": "info"},
    "14": {"area": "Tables & Storage", "risk": "medium"},
    "15": {"area": "Vacuum & Stats",   "risk": "medium"},
    "16": {"area": "Vacuum & Stats",   "risk": "high"},
    "17": {"area": "Vacuum & Stats",   "risk": "medium"},
    "18": {"area": "Vacuum & Stats",   "risk": "high"},
    "19": {"area": "Connections",      "risk": "high"},
    "20": {"area": "Connections",      "risk": "high"},
    "21": {"area": "Connections",      "risk": "high"},
    "22": {"area": "Connections",      "risk": "medium"},
    "23": {"area": "Replication",      "risk": "high"},
    "24": {"area": "Replication",      "risk": "high"},
    "25": {"area": "Replication",      "risk": "medium"},
    "26": {"area": "Risk Signals",     "risk": "critical"},
    "27": {"area": "Risk Signals",     "risk": "critical"},
    "28": {"area": "Risk Signals",     "risk": "high"},
    "29": {"area": "Config & Health",  "risk": "info"},
    "30": {"area": "Config & Health",  "risk": "medium"},
    "31": {"area": "Config & Health",  "risk": "medium"},
    "32": {"area": "Config & Health",  "risk": "info"},
    "33": {"area": "Config & Health",  "risk": "medium"},
    "34": {"area": "Tables & Storage",      "risk": "low"},
    "35": {"area": "Risk Signals",           "risk": "high"},
    "36": {"area": "Config & Health",        "risk": "medium"},
    "37": {"area": "Inventory & Extensions", "risk": "medium"},
    "38": {"area": "Inventory & Extensions", "risk": "medium"},
    "39": {"area": "Inventory & Extensions", "risk": "low"},
    "40": {"area": "Inventory & Extensions", "risk": "info"},
}


# ════════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════════

def load_config(config_path: Path | None, profile: str | None) -> dict:
    """Load and merge configuration from file, profile, and environment."""
    cfg: dict[str, Any] = {
        "host": "localhost",
        "port": 5432,
        "user": "postgres",
        "password": "",
        "database": "postgres",
        "sslmode": "prefer",
        "psql_path": "psql",
        "sql_dir": str(DEFAULT_SQL),
        "timeout_seconds": 30,
        "sections": "all",
        "skip_sections": [],
        "output_dir": str(SCRIPT_DIR / "reports"),
        "format": "markdown",
        "include_raw_output": True,
        "truncate_rows": 60,
        "filename_template": "pgvitals_{database}_{timestamp}.md",
    }

    # ── Layer 1: Config file ────────────────────────────────────────
    if config_path is None:
        config_path = DEFAULT_CFG
    if config_path.exists():
        with open(config_path, "r", encoding="utf-8") as f:
            raw = json.load(f)

        # Base connection
        conn = raw.get("connection", {})
        for k in ("host", "port", "user", "password", "database", "sslmode"):
            if k in conn:
                cfg[k] = conn[k]

        # Runner
        runner = raw.get("runner", {})
        for k in ("psql_path", "sql_dir", "timeout_seconds", "sections", "skip_sections"):
            if k in runner:
                cfg[k] = runner[k]

        # Report
        report = raw.get("report", {})
        for k in ("output_dir", "format", "include_raw_output", "truncate_rows", "filename_template"):
            if k in report:
                cfg[k] = report[k]

        # ── Layer 2: Named profile (overrides base connection) ──────
        if profile and profile in raw.get("profiles", {}):
            p = raw["profiles"][profile]
            for k in ("host", "port", "user", "password", "database", "sslmode"):
                if k in p:
                    cfg[k] = p[k]
            print(f"🔗 Using profile: {profile}")
        elif profile:
            print(f"⚠  Profile '{profile}' not found in config, using defaults")

    else:
        print(f"ℹ  No config file at {config_path}, using CLI args / env vars")

    # ── Layer 3: Environment variables (highest priority) ───────────
    env_map = {
        "PGHOST": "host",
        "PGPORT": "port",
        "PGUSER": "user",
        "PGPASSWORD": "password",
        "PGDATABASE": "database",
    }
    for env_key, cfg_key in env_map.items():
        val = os.environ.get(env_key)
        if val:
            cfg[cfg_key] = int(val) if cfg_key == "port" else val

    # Resolve relative sql_dir
    sql_dir = Path(cfg["sql_dir"])
    if not sql_dir.is_absolute():
        cfg["sql_dir"] = str((SCRIPT_DIR / sql_dir).resolve())

    return cfg


# ════════════════════════════════════════════════════════════════════
# SQL Execution
# ════════════════════════════════════════════════════════════════════

def parse_header(sql_text: str) -> dict[str, str]:
    """Extract What / Look for / Action / Requires from the SQL header."""
    info: dict[str, str] = {}
    for key in ("What", "Look for", "Action", "Requires"):
        m = re.search(rf"--\s*{key}\s*:\s*(.+?)(?:\n|$)", sql_text, re.IGNORECASE)
        if m:
            info[key] = m.group(1).strip()
    return info


def strip_header_comments(sql_text: str) -> str:
    """Remove all whole-line comments and empty lines to keep the body clean and prevent encoding errors."""
    lines = sql_text.splitlines()
    body: list[str] = []
    for line in lines:
        s = line.strip()
        if s.startswith("--") or s == "":
            continue
        body.append(line)
    return "\n".join(body).strip()


def run_query(
    psql_path: str,
    host: str,
    port: int,
    user: str,
    password: str,
    database: str,
    sql_filepath: str,
    timeout: int,
) -> tuple[str, str, int]:
    """Execute a SQL file via psql and return (stdout, stderr, returncode)."""
    env = os.environ.copy()
    if password:
        env["PGPASSWORD"] = str(password)

    with open(sql_filepath, "r", encoding="utf-8") as f:
        sql = f.read()

    body = strip_header_comments(sql)
    if not body:
        return ("(empty query)", "", 0)

    try:
        proc = subprocess.run(
            [
                psql_path,
                "-h", str(host),
                "-p", str(port),
                "-U", str(user),
                "-d", str(database),
                "--no-psqlrc",
                "-X",
                "-P", "pager=off",
                "-P", "footer=on",
                "-c", body,
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=timeout,
        )
        return (proc.stdout, proc.stderr, proc.returncode)
    except subprocess.TimeoutExpired:
        return ("", f"TIMEOUT: Query exceeded {timeout}s limit", 1)
    except FileNotFoundError:
        return ("", f"ERROR: psql not found at '{psql_path}'. Set psql_path in config or add to PATH.", 1)
    except Exception as e:
        return ("", f"EXCEPTION: {e}", 1)


# ════════════════════════════════════════════════════════════════════
# Analysis Engine
# ════════════════════════════════════════════════════════════════════

def classify_result(section_id: str, stdout: str, stderr: str, rc: int) -> str:
    """Return a status badge based on query results."""
    if rc != 0 or "ERROR" in stderr:
        return "⚠️ Error"
    if "(0 rows)" in stdout or stdout.strip() == "":
        return "✅ Clear"
    return "📊 Data"


def count_rows(stdout: str) -> int | None:
    """Extract row count from psql output footer."""
    m = re.search(r"\((\d+) rows?\)", stdout)
    return int(m.group(1)) if m else None


def error_analysis(stderr: str) -> str:
    """Provide a human-readable explanation for common errors."""
    s = stderr.lower()
    if "permission denied" in s:
        return "Requires elevated privileges (e.g., `pg_monitor` role)."
    if "pg_stat_statements" in s and "does not exist" in s:
        return "Requires `pg_stat_statements` extension. Install it via `CREATE EXTENSION pg_stat_statements;`."
    if "pg_stat_io" in s and "does not exist" in s:
        return "`pg_stat_io` requires PostgreSQL 16+ and appropriate permissions."
    if "does not exist" in s:
        return "Referenced catalog view or column not available in this environment."
    if "timeout" in s:
        return "Query timed out — large catalog or complex join."
    if "connection refused" in s:
        return "Cannot connect to the database. Check host/port/firewall."
    if "password authentication failed" in s:
        return "Authentication failed. Check user/password."
    return stderr.split("\n")[0][:120]


# ════════════════════════════════════════════════════════════════════
# Report Generator
# ════════════════════════════════════════════════════════════════════

def generate_report(
    results: list[dict],
    cfg: dict,
    pg_version: str,
) -> str:
    """Generate the full Markdown report from query results."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines: list[str] = []

    # ── Header ──────────────────────────────────────────────────────
    lines.append("# 🩺 pgvitals Diagnostic Report")
    lines.append("")
    lines.append(f"> **Database**: `{cfg['database']}` on `{cfg['host']}:{cfg['port']}`  ")
    lines.append(f"> **PostgreSQL Version**: {pg_version}  ")
    lines.append(f"> **Connected As**: `{cfg['user']}`  ")
    lines.append(f"> **Report Generated**: {now}  ")
    lines.append(f"> **Sections Executed**: {len(results)}")
    lines.append("")

    # ── Summary Table ───────────────────────────────────────────────
    lines.append("## 📋 Executive Summary")
    lines.append("")
    lines.append("| # | Section | Area | Risk | Status | Findings |")
    lines.append("|---|---------|------|------|--------|----------|")

    for r in results:
        meta = SECTION_META.get(r["num"], {"area": "—", "risk": "—"})
        finding = ""
        if r["badge"] == "✅ Clear":
            finding = "No issues detected"
        elif r["badge"] == "⚠️ Error":
            finding = error_analysis(r["stderr"])[:60]
        else:
            rc = count_rows(r["stdout"])
            finding = f"{rc} rows returned" if rc else "Results available"
        lines.append(
            f"| {r['num']} | {r['title']} | {meta['area']} "
            f"| {meta['risk']} | {r['badge']} | {finding} |"
        )
    lines.append("")

    # ── Health Score ────────────────────────────────────────────────
    total       = len(results)
    clear_count = sum(1 for r in results if r["badge"] == "✅ Clear")
    data_count  = sum(1 for r in results if r["badge"] == "📊 Data")
    error_count = sum(1 for r in results if r["badge"] == "⚠️ Error")

    lines.append("## 🏥 Health Score Overview")
    lines.append("")
    lines.append("| Metric | Count | Percentage |")
    lines.append("|--------|-------|------------|")
    lines.append(f"| ✅ Clear (No Issues) | {clear_count} | {round(clear_count/total*100)}% |")
    lines.append(f"| 📊 Data (Findings)   | {data_count}  | {round(data_count/total*100)}% |")
    lines.append(f"| ⚠️ Error (Unavailable) | {error_count} | {round(error_count/total*100)}% |")
    lines.append("")

    # ── Area Breakdown ──────────────────────────────────────────────
    areas: dict[str, dict[str, int]] = {}
    for r in results:
        area = SECTION_META.get(r["num"], {}).get("area", "Other")
        if area not in areas:
            areas[area] = {"clear": 0, "data": 0, "error": 0}
        if r["badge"] == "✅ Clear":
            areas[area]["clear"] += 1
        elif r["badge"] == "📊 Data":
            areas[area]["data"] += 1
        else:
            areas[area]["error"] += 1

    lines.append("### Breakdown by Area")
    lines.append("")
    lines.append("| Area | ✅ Clear | 📊 Data | ⚠️ Error |")
    lines.append("|------|----------|---------|----------|")
    for area, counts in areas.items():
        lines.append(f"| {area} | {counts['clear']} | {counts['data']} | {counts['error']} |")
    lines.append("")

    # ── Detailed Sections ───────────────────────────────────────────
    lines.append("---")
    lines.append("")
    lines.append("## 🔍 Detailed Section Results")
    lines.append("")

    truncate = cfg.get("truncate_rows", 60)

    for r in results:
        lines.append(f"### Section {r['num']} — {r['title']}")
        lines.append("")

        if r["header"]:
            for key in ("What", "Look for", "Action", "Requires"):
                if key in r["header"]:
                    lines.append(f"**{key}**: {r['header'][key]}  ")
            lines.append("")

        lines.append(f"**Status**: {r['badge']}  ")
        meta = SECTION_META.get(r["num"], {})
        if meta.get("risk"):
            risk_icon = {"critical": "🔴", "high": "🟠", "medium": "🟡", "low": "🟢", "info": "ℹ️"}.get(meta["risk"], "")
            lines.append(f"**Risk Level**: {risk_icon} {meta['risk'].upper()}")
        lines.append("")

        if r["badge"] == "⚠️ Error":
            lines.append("<details>")
            lines.append("<summary>⚠️ Error Details</summary>")
            lines.append("")
            lines.append("```")
            lines.append(r["stderr"][:500])
            lines.append("```")
            lines.append("</details>")
            lines.append("")
            lines.append(f"> [!NOTE]")
            lines.append(f"> {error_analysis(r['stderr'])}")
            lines.append("")

        elif r["stdout"] and cfg.get("include_raw_output", True):
            output = r["stdout"]
            out_lines = output.split("\n")
            if len(out_lines) > truncate:
                output = "\n".join(out_lines[:truncate - 5])
                output += f"\n... ({len(out_lines) - truncate + 5} more rows truncated)"

            lines.append("```")
            lines.append(output)
            lines.append("```")
            lines.append("")
        else:
            lines.append("*No output returned.*")
            lines.append("")

        lines.append("---")
        lines.append("")

    # ── Recommendations ─────────────────────────────────────────────
    lines.append("## 📊 Recommendations")
    lines.append("")

    critical_findings = [r for r in results if r["badge"] == "📊 Data"
                         and SECTION_META.get(r["num"], {}).get("risk") in ("critical", "high")]
    if critical_findings:
        lines.append("### 🔴 High Priority Actions")
        lines.append("")
        for r in critical_findings:
            action = r["header"].get("Action", "Investigate findings")
            lines.append(f"- **Section {r['num']} ({r['title']})**: {action}")
        lines.append("")

    medium_findings = [r for r in results if r["badge"] == "📊 Data"
                       and SECTION_META.get(r["num"], {}).get("risk") == "medium"]
    if medium_findings:
        lines.append("### 🟡 Medium Priority")
        lines.append("")
        for r in medium_findings:
            action = r["header"].get("Action", "Review findings")
            lines.append(f"- **Section {r['num']} ({r['title']})**: {action}")
        lines.append("")

    if error_count > 0:
        lines.append("### ℹ️ Sections Requiring Elevated Access")
        lines.append("")
        for r in results:
            if r["badge"] == "⚠️ Error":
                lines.append(f"- Section {r['num']} — {r['title']}")
        lines.append("")
        lines.append("> [!TIP]")
        lines.append("> For full coverage, run with a user that has `pg_monitor` role and `pg_stat_statements` installed.")
        lines.append("")

    return "\n".join(lines)


# ════════════════════════════════════════════════════════════════════
# CLI Entry Point
# ════════════════════════════════════════════════════════════════════

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="pgvitals",
        description="Run pgvitals diagnostic queries and generate a health report.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python run_diagnostics.py                          # Use pgvitals.conf defaults
  python run_diagnostics.py --profile staging         # Named profile from config
  python run_diagnostics.py --host db.example.com     # Override host via CLI
  python run_diagnostics.py --sections 01,03,19,26    # Run specific sections
  python run_diagnostics.py --skip 05,36              # Skip specific sections
        """,
    )

    # Connection
    g = p.add_argument_group("Connection")
    g.add_argument("--host", help="Database host")
    g.add_argument("--port", type=int, help="Database port")
    g.add_argument("--user", "-U", help="Database user")
    g.add_argument("--password", help="Database password (prefer PGPASSWORD env var)")
    g.add_argument("--database", "-d", help="Database name")
    g.add_argument("--profile", help="Named connection profile from config file")

    # Runner
    g2 = p.add_argument_group("Runner")
    g2.add_argument("--config", type=Path, help=f"Config file path (default: {DEFAULT_CFG})")
    g2.add_argument("--psql", help="Path to psql binary")
    g2.add_argument("--sql-dir", help="Path to SQL files directory")
    g2.add_argument("--sections", help="Comma-separated section numbers to run (e.g., 01,03,19)")
    g2.add_argument("--skip", help="Comma-separated section numbers to skip")
    g2.add_argument("--timeout", type=int, help="Query timeout in seconds")

    # Report
    g3 = p.add_argument_group("Report")
    g3.add_argument("--output", "-o", help="Output file path (default: auto-generated)")
    g3.add_argument("--no-raw", action="store_true", help="Omit raw query output from report")

    return p.parse_args()


def main() -> int:
    args = parse_args()

    # ── Load config ─────────────────────────────────────────────────
    cfg = load_config(args.config, args.profile)

    # ── CLI overrides (highest priority after env) ──────────────────
    if args.host:       cfg["host"]       = args.host
    if args.port:       cfg["port"]       = args.port
    if args.user:       cfg["user"]       = args.user
    if args.password:   cfg["password"]   = args.password
    if args.database:   cfg["database"]   = args.database
    if args.psql:       cfg["psql_path"]  = args.psql
    if args.sql_dir:    cfg["sql_dir"]    = args.sql_dir
    if args.timeout:    cfg["timeout_seconds"] = args.timeout
    if args.no_raw:     cfg["include_raw_output"] = False

    # ── Resolve sections ────────────────────────────────────────────
    sql_dir = Path(cfg["sql_dir"])
    if not sql_dir.exists():
        print(f"❌ SQL directory not found: {sql_dir}")
        return 1

    all_files = sorted(
        [f for f in os.listdir(sql_dir) if f.endswith(".sql") and f[0].isdigit()],
        key=lambda x: int(re.match(r"(\d+)", x).group(1)),
    )

    # Filter sections
    requested = args.sections or cfg.get("sections", "all")
    if requested != "all":
        wanted = set(s.strip().zfill(2) for s in requested.split(","))
        all_files = [f for f in all_files if re.match(r"(\d+)", f).group(1).zfill(2) in wanted]

    skip_list = set()
    skip_raw = args.skip or cfg.get("skip_sections", [])
    if skip_raw:
        if isinstance(skip_raw, str):
            skip_raw = skip_raw.split(",")
        skip_list = set(s.strip().zfill(2) for s in skip_raw)
        all_files = [f for f in all_files if re.match(r"(\d+)", f).group(1).zfill(2) not in skip_list]

    if not all_files:
        print("❌ No SQL files matched the section filter.")
        return 1

    # ── Print banner ────────────────────────────────────────────────
    print("╔══════════════════════════════════════════════════════╗")
    print("║          🩺  pgvitals diagnostic runner              ║")
    print("╚══════════════════════════════════════════════════════╝")
    print(f"  Host     : {cfg['host']}:{cfg['port']}")
    print(f"  Database : {cfg['database']}")
    print(f"  User     : {cfg['user']}")
    print(f"  Sections : {len(all_files)}")
    print(f"  Timeout  : {cfg['timeout_seconds']}s per query")
    print()

    # ── Test connection ─────────────────────────────────────────────
    print("Testing connection...", end=" ", flush=True)
    env = os.environ.copy()
    if cfg["password"]:
        env["PGPASSWORD"] = str(cfg["password"])
    try:
        proc = subprocess.run(
            [
                cfg["psql_path"],
                "-h", str(cfg["host"]),
                "-p", str(cfg["port"]),
                "-U", str(cfg["user"]),
                "-d", str(cfg["database"]),
                "--no-psqlrc", "-X",
                "-P", "pager=off",
                "-t", "-A",
                "-c", "SELECT version();",
            ],
            capture_output=True, text=True, env=env,
            timeout=cfg["timeout_seconds"],
        )
        if proc.returncode != 0:
            print(f"FAILED\n  {proc.stderr.strip()}")
            return 1
        pg_version = proc.stdout.strip().split(",")[0].replace("PostgreSQL ", "")
        print(f"OK — PostgreSQL {pg_version}")
    except Exception as e:
        print(f"FAILED — {e}")
        return 1

    print()

    # ── Execute all sections ────────────────────────────────────────
    results: list[dict] = []
    total = len(all_files)

    for idx, fname in enumerate(all_files, 1):
        fpath = str(sql_dir / fname)
        section_num = re.match(r"(\d+)", fname).group(1).zfill(2)
        parts = fname.replace(".sql", "").split("_", 1)
        title = parts[1].replace("_", " ").title() if len(parts) > 1 else fname

        with open(fpath, "r", encoding="utf-8") as f:
            sql_text = f.read()
        header = parse_header(sql_text)

        bar_filled = int(idx / total * 30)
        bar = "█" * bar_filled + "░" * (30 - bar_filled)
        print(f"\r  [{bar}] {idx}/{total}  Section {section_num}: {title[:35]:<35}", end="", flush=True)

        stdout, stderr, rc = run_query(
            cfg["psql_path"], cfg["host"], cfg["port"], cfg["user"],
            cfg["password"], cfg["database"], fpath, cfg["timeout_seconds"],
        )

        badge = classify_result(section_num, stdout, stderr, rc)

        results.append({
            "num": section_num,
            "file": fname,
            "title": title,
            "header": header,
            "stdout": stdout.strip(),
            "stderr": stderr.strip(),
            "rc": rc,
            "badge": badge,
        })

    print()  # newline after progress bar
    print()

    # ── Generate report ─────────────────────────────────────────────
    report = generate_report(results, cfg, pg_version)

    # ── Determine output path ───────────────────────────────────────
    if args.output:
        output_path = Path(args.output)
    else:
        out_dir = Path(cfg["output_dir"])
        out_dir.mkdir(parents=True, exist_ok=True)
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = cfg["filename_template"].format(
            database=cfg["database"],
            timestamp=ts,
            host=cfg["host"].replace(".", "_"),
        )
        output_path = out_dir / filename

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(report)

    # ── Summary ─────────────────────────────────────────────────────
    clear_count = sum(1 for r in results if r["badge"] == "✅ Clear")
    data_count  = sum(1 for r in results if r["badge"] == "📊 Data")
    error_count = sum(1 for r in results if r["badge"] == "⚠️ Error")

    print("╔══════════════════════════════════════════════════════╗")
    print("║                    Results Summary                   ║")
    print("╠══════════════════════════════════════════════════════╣")
    print(f"║  ✅ Clear  : {clear_count:>3}                                    ║")
    print(f"║  📊 Data   : {data_count:>3}                                    ║")
    print(f"║  ⚠️ Error  : {error_count:>3}                                    ║")
    print(f"║  Total     : {total:>3}                                    ║")
    print("╠══════════════════════════════════════════════════════╣")
    print(f"║  Report: {str(output_path)[:42]:<42} ║")
    print("╚══════════════════════════════════════════════════════╝")

    return 0


if __name__ == "__main__":
    sys.exit(main())
