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

    # Machine-readable output
    python run_diagnostics.py --format json --output ./report.json
    python run_diagnostics.py --format prometheus --output ./pgvitals.prom

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
import html
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

# Stable schema version for machine-readable output (--format json).
# Bump only on a breaking change to the JSON shape.
JSON_SCHEMA_VERSION = "1.0"

# Best-effort tool version (available when run as the installed package).
try:
    from pgvitals import __version__ as PGVITALS_VERSION
except Exception:  # noqa: BLE001 — runner can be executed standalone
    PGVITALS_VERSION = "dev"

# File extension per output format.
FORMAT_EXT = {"markdown": ".md", "html": ".html", "json": ".json", "prometheus": ".prom"}

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


def section_status(badge: str) -> str:
    """Map a display badge to a stable, machine-readable status token.

    Used by the JSON and Prometheus outputs so consumers never have to parse
    emoji. Mirrors classify_result's three outcomes.
    """
    if badge == "✅ Clear":
        return "clear"
    if badge == "📊 Data":
        return "findings"
    return "error"


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


# ── Scoring (shared by the HTML report) ─────────────────────────────
RISK_PENALTY = {"critical": 25, "high": 15, "medium": 7, "low": 3, "info": 0}
RISK_COLOR   = {
    "critical": "#dc2626", "high": "#ea580c", "medium": "#d97706",
    "low": "#16a34a", "info": "#64748b",
}


def compute_score(results: list[dict]) -> int:
    """Derive a 0–100 health score from section findings.

    Sections that returned data are penalized by their risk weight. Errors do
    not penalize the score (the check was unavailable, not failed) — they are
    surfaced separately as a coverage gap.
    """
    score = 100
    for r in results:
        if r["badge"] == "📊 Data":
            risk = SECTION_META.get(r["num"], {}).get("risk", "info")
            score -= RISK_PENALTY.get(risk, 0)
    return max(0, min(100, score))


def grade_for(score: int) -> tuple[str, str, str]:
    """Return (letter, label, color) for a score."""
    if score >= 90:
        return ("A", "Excellent", "#16a34a")
    if score >= 80:
        return ("B", "Good", "#65a30d")
    if score >= 70:
        return ("C", "Fair", "#d97706")
    if score >= 60:
        return ("D", "Poor", "#ea580c")
    return ("F", "Critical", "#dc2626")


# ════════════════════════════════════════════════════════════════════
# Report Generator
# ════════════════════════════════════════════════════════════════════

def generate_report(
    results: list[dict],
    cfg: dict,
    pg_version: str,
    ai_analysis: str | None = None,
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

    # ── AI Analysis (optional) ──────────────────────────────────────
    if ai_analysis:
        lines.append("## 🧠 AI Analysis")
        lines.append("")
        lines.append(ai_analysis)
        lines.append("")
        lines.append("---")
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
# HTML Report Generator (self-contained, no external dependencies)
# ════════════════════════════════════════════════════════════════════

_HTML_CSS = """
:root { --bg:#f6f7f9; --card:#fff; --ink:#0f172a; --muted:#64748b;
        --line:#e5e7eb; --accent:#0ea5e9; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink);
       font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
.wrap { max-width:960px; margin:0 auto; padding:32px 20px 64px; }
a { color:var(--accent); }
.banner { background:linear-gradient(135deg,#0f172a,#1e293b); color:#fff;
          border-radius:16px; padding:28px 32px; margin-bottom:24px; }
.banner h1 { margin:0 0 4px; font-size:26px; letter-spacing:-0.5px; }
.banner .sub { color:#94a3b8; font-size:13px; }
.meta { display:flex; flex-wrap:wrap; gap:6px 28px; margin-top:16px; font-size:13px; }
.meta b { color:#cbd5e1; font-weight:600; }
.meta span { color:#fff; }
.scorecard { display:flex; gap:28px; align-items:center; background:var(--card);
             border:1px solid var(--line); border-radius:16px; padding:24px 28px; margin-bottom:24px; }
.gauge { flex:0 0 auto; }
.score-body { flex:1 1 auto; }
.grade { font-size:22px; font-weight:700; }
.score-label { color:var(--muted); margin:2px 0 14px; }
.pills { display:flex; flex-wrap:wrap; gap:10px; }
.pill { display:inline-flex; align-items:center; gap:7px; padding:6px 12px;
        border-radius:999px; font-size:13px; font-weight:600; background:#f1f5f9; }
.dot { width:9px; height:9px; border-radius:50%; display:inline-block; }
.dot.clear{background:#16a34a;} .dot.data{background:#0ea5e9;} .dot.error{background:#94a3b8;}
.section-title { font-size:13px; text-transform:uppercase; letter-spacing:.6px;
                 color:var(--muted); margin:28px 0 12px; font-weight:700; }
table.areas { width:100%; border-collapse:collapse; background:var(--card);
              border:1px solid var(--line); border-radius:12px; overflow:hidden; }
table.areas th, table.areas td { padding:10px 14px; text-align:left; font-size:13px;
              border-bottom:1px solid var(--line); }
table.areas th { background:#f8fafc; color:var(--muted); font-weight:600; }
table.areas td.num { text-align:right; font-variant-numeric:tabular-nums; }
.toolbar { display:flex; gap:8px; margin:24px 0 12px; }
.btn { border:1px solid var(--line); background:var(--card); color:var(--ink);
       padding:7px 14px; border-radius:8px; font-size:13px; cursor:pointer; }
.btn:hover { background:#f1f5f9; }
details.section { background:var(--card); border:1px solid var(--line);
                 border-radius:12px; margin-bottom:10px; overflow:hidden; }
details.section > summary { list-style:none; cursor:pointer; padding:14px 18px;
       display:flex; align-items:center; gap:12px; }
details.section > summary::-webkit-details-marker { display:none; }
.sec-num { font-variant-numeric:tabular-nums; color:var(--muted); font-weight:700;
           font-size:13px; min-width:24px; }
.sec-name { font-weight:600; flex:1 1 auto; }
.risk { font-size:11px; font-weight:700; text-transform:uppercase; letter-spacing:.4px;
        color:#fff; padding:3px 9px; border-radius:999px; }
.sec-body { padding:0 18px 18px; border-top:1px solid var(--line); }
.hdr { margin:14px 0; font-size:13.5px; }
.hdr div { margin:3px 0; }
.hdr b { color:var(--muted); font-weight:600; display:inline-block; min-width:74px; }
pre { background:#0f172a; color:#e2e8f0; border-radius:10px; padding:14px 16px;
      overflow-x:auto; font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
      margin:10px 0 0; }
.errbox { background:#fef2f2; border:1px solid #fecaca; color:#991b1b;
          border-radius:10px; padding:12px 14px; margin-top:10px; font-size:13px; }
.note { color:var(--muted); font-size:13px; margin-top:8px; }
.recs li { margin:5px 0; }
.ai { background:linear-gradient(180deg,#faf5ff,#fff); border:1px solid #e9d5ff;
      border-radius:14px; padding:18px 22px; margin-bottom:24px; }
.ai-head { font-weight:700; color:#7c3aed; font-size:15px; margin-bottom:8px; }
.ai-body { font-size:14px; }
.ai-body h3, .ai-body h4 { font-size:14px; margin:14px 0 6px; color:#0f172a; }
.ai-body p { margin:8px 0; }
.ai-body ul, .ai-body ol { margin:8px 0 8px 22px; }
.ai-body li { margin:4px 0; }
.ai-body code { background:#f1f5f9; padding:1px 6px; border-radius:5px;
      font:12.5px ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
.ai-body pre { background:#0f172a; color:#e2e8f0; }
footer { color:var(--muted); font-size:12px; text-align:center; margin-top:40px; }
@media print { body{background:#fff;} .toolbar{display:none;}
               details.section{open:true;} .banner{-webkit-print-color-adjust:exact;} }
"""

_HTML_JS = """
function pgvSetAll(open){
  document.querySelectorAll('details.section').forEach(function(d){ d.open = open; });
}
"""


def _status_class(badge: str) -> str:
    if badge == "✅ Clear":
        return "clear"
    if badge == "📊 Data":
        return "data"
    return "error"


def _md_to_html_min(md: str) -> str:
    """Tiny, safe Markdown→HTML for the AI analysis block.

    HTML-escapes first, then applies a small, fixed set of transforms
    (headings, bullet/numbered lists, bold, inline + fenced code). Anything
    not recognized is rendered as a paragraph — no arbitrary HTML passes through.
    """
    import re as _re
    esc = html.escape
    out: list[str] = []
    list_type: str | None = None        # 'ul' | 'ol' | None
    in_code = False
    code_buf: list[str] = []

    def close_list() -> None:
        nonlocal list_type
        if list_type:
            out.append(f"</{list_type}>")
            list_type = None

    def inline(s: str) -> str:
        s = esc(s)
        s = _re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        s = _re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        return s

    for raw in md.splitlines():
        line = raw.rstrip()

        if line.strip().startswith("```"):
            if in_code:
                out.append("<pre>" + esc("\n".join(code_buf)) + "</pre>")
                code_buf = []
                in_code = False
            else:
                close_list()
                in_code = True
            continue
        if in_code:
            code_buf.append(raw)
            continue

        if not line.strip():
            close_list()
            continue

        m = _re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            close_list()
            level = min(max(len(m.group(1)), 3), 6)   # floor at h3 so it stays under the card title
            out.append(f"<h{level}>{inline(m.group(2))}</h{level}>")
            continue

        m = _re.match(r"^\s*[-*]\s+(.*)$", line)
        if m:
            if list_type != "ul":
                close_list(); out.append("<ul>"); list_type = "ul"
            out.append(f"<li>{inline(m.group(1))}</li>")
            continue

        m = _re.match(r"^\s*\d+[.)]\s+(.*)$", line)
        if m:
            if list_type != "ol":
                close_list(); out.append("<ol>"); list_type = "ol"
            out.append(f"<li>{inline(m.group(1))}</li>")
            continue

        close_list()
        out.append(f"<p>{inline(line)}</p>")

    if in_code:
        out.append("<pre>" + esc("\n".join(code_buf)) + "</pre>")
    close_list()
    return "\n".join(out)


def generate_html_report(results: list[dict], cfg: dict, pg_version: str,
                         ai_analysis: str | None = None) -> str:
    """Render a single self-contained HTML report (no external assets)."""
    esc = html.escape
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    truncate = cfg.get("truncate_rows", 60)

    total       = len(results)
    clear_count = sum(1 for r in results if r["badge"] == "✅ Clear")
    data_count  = sum(1 for r in results if r["badge"] == "📊 Data")
    error_count = sum(1 for r in results if r["badge"] == "⚠️ Error")

    score = compute_score(results)
    letter, label, gcolor = grade_for(score)

    # Donut gauge geometry
    radius = 54.0
    circ = 2 * 3.141592653589793 * radius
    dash = circ * score / 100.0

    out: list[str] = []
    out.append("<!DOCTYPE html>")
    out.append('<html lang="en"><head><meta charset="utf-8">')
    out.append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    out.append(f"<title>pgvitals report — {esc(cfg['database'])}</title>")
    out.append(f"<style>{_HTML_CSS}</style></head><body><div class=\"wrap\">")

    # ── Banner ──
    out.append('<div class="banner">')
    out.append('<h1>🩺 pgvitals Diagnostic Report</h1>')
    out.append('<div class="sub">PostgreSQL health diagnostics</div>')
    out.append('<div class="meta">')
    out.append(f'<div><b>Database</b> <span>{esc(cfg["database"])}</span></div>')
    out.append(f'<div><b>Host</b> <span>{esc(str(cfg["host"]))}:{esc(str(cfg["port"]))}</span></div>')
    out.append(f'<div><b>Version</b> <span>PostgreSQL {esc(pg_version)}</span></div>')
    out.append(f'<div><b>User</b> <span>{esc(str(cfg["user"]))}</span></div>')
    out.append(f'<div><b>Generated</b> <span>{esc(now)}</span></div>')
    out.append(f'<div><b>Sections</b> <span>{total}</span></div>')
    out.append('</div></div>')

    # ── Scorecard with gauge ──
    out.append('<div class="scorecard">')
    out.append(f'<svg class="gauge" width="120" height="120" viewBox="0 0 140 140">')
    out.append('<circle cx="70" cy="70" r="54" fill="none" stroke="#e5e7eb" stroke-width="14"/>')
    out.append(f'<circle cx="70" cy="70" r="54" fill="none" stroke="{gcolor}" stroke-width="14" '
               f'stroke-linecap="round" stroke-dasharray="{dash:.1f} {circ:.1f}" '
               f'transform="rotate(-90 70 70)"/>')
    out.append(f'<text x="70" y="74" text-anchor="middle" font-size="34" font-weight="700" '
               f'fill="{gcolor}" font-family="sans-serif">{score}</text>')
    out.append('<text x="70" y="96" text-anchor="middle" font-size="12" fill="#94a3b8" '
               'font-family="sans-serif">/ 100</text></svg>')
    out.append('<div class="score-body">')
    out.append(f'<div class="grade" style="color:{gcolor}">Grade {letter} — {esc(label)}</div>')
    out.append('<div class="score-label">Derived from section findings weighted by risk</div>')
    out.append('<div class="pills">')
    out.append(f'<span class="pill"><span class="dot clear"></span>{clear_count} Clear</span>')
    out.append(f'<span class="pill"><span class="dot data"></span>{data_count} With findings</span>')
    out.append(f'<span class="pill"><span class="dot error"></span>{error_count} Unavailable</span>')
    out.append('</div></div></div>')

    # ── AI analysis (optional) ──
    if ai_analysis:
        out.append('<div class="ai"><div class="ai-head">🧠 AI Analysis</div>')
        out.append('<div class="ai-body">' + _md_to_html_min(ai_analysis) + '</div></div>')

    # ── Area breakdown ──
    areas: dict[str, dict[str, int]] = {}
    for r in results:
        area = SECTION_META.get(r["num"], {}).get("area", "Other")
        a = areas.setdefault(area, {"clear": 0, "data": 0, "error": 0})
        a[_status_class(r["badge"])] += 1

    out.append('<div class="section-title">Breakdown by area</div>')
    out.append('<table class="areas"><thead><tr><th>Area</th>'
               '<th class="num">Clear</th><th class="num">Findings</th>'
               '<th class="num">Unavailable</th></tr></thead><tbody>')
    for area, c in areas.items():
        out.append(f'<tr><td>{esc(area)}</td><td class="num">{c["clear"]}</td>'
                   f'<td class="num">{c["data"]}</td><td class="num">{c["error"]}</td></tr>')
    out.append('</tbody></table>')

    # ── Toolbar ──
    out.append('<div class="section-title">Sections</div>')
    out.append('<div class="toolbar">')
    out.append('<button class="btn" onclick="pgvSetAll(true)">Expand all</button>')
    out.append('<button class="btn" onclick="pgvSetAll(false)">Collapse all</button>')
    out.append('<button class="btn" onclick="window.print()">Print / Save PDF</button>')
    out.append('</div>')

    # ── Section cards ──
    for r in results:
        meta = SECTION_META.get(r["num"], {})
        risk = meta.get("risk", "info")
        rcolor = RISK_COLOR.get(risk, "#64748b")
        sclass = _status_class(r["badge"])
        is_open = " open" if r["badge"] in ("📊 Data", "⚠️ Error") else ""
        out.append(f'<details class="section"{is_open}>')
        out.append('<summary>')
        out.append(f'<span class="dot {sclass}"></span>')
        out.append(f'<span class="sec-num">{esc(r["num"])}</span>')
        out.append(f'<span class="sec-name">{esc(r["title"])}</span>')
        out.append(f'<span class="risk" style="background:{rcolor}">{esc(risk)}</span>')
        out.append('</summary>')
        out.append('<div class="sec-body">')

        if r.get("header"):
            out.append('<div class="hdr">')
            for key in ("What", "Look for", "Action", "Requires"):
                if key in r["header"]:
                    out.append(f'<div><b>{key}</b> {esc(r["header"][key])}</div>')
            out.append('</div>')

        if r["badge"] == "⚠️ Error":
            out.append(f'<div class="errbox">{esc(r["stderr"][:500])}</div>')
            out.append(f'<div class="note">{esc(error_analysis(r["stderr"]))}</div>')
        elif r["stdout"] and cfg.get("include_raw_output", True):
            output = r["stdout"]
            ol = output.split("\n")
            if len(ol) > truncate:
                output = "\n".join(ol[:truncate - 5])
                output += f"\n... ({len(ol) - truncate + 5} more rows truncated)"
            out.append(f'<pre>{esc(output)}</pre>')
        else:
            out.append('<div class="note">No output returned.</div>')

        out.append('</div></details>')

    # ── Recommendations ──
    high = [r for r in results if r["badge"] == "📊 Data"
            and SECTION_META.get(r["num"], {}).get("risk") in ("critical", "high")]
    med = [r for r in results if r["badge"] == "📊 Data"
           and SECTION_META.get(r["num"], {}).get("risk") == "medium"]
    if high or med:
        out.append('<div class="section-title">Recommendations</div>')
        out.append('<ul class="recs">')
        for r in high + med:
            action = r.get("header", {}).get("Action", "Investigate findings")
            out.append(f'<li><b>{esc(r["num"])} {esc(r["title"])}</b> — {esc(action)}</li>')
        out.append('</ul>')

    out.append('<footer>Generated by '
               '<a href="https://github.com/pgvitals/pgvitals">pgvitals</a> · '
               'read-only PostgreSQL diagnostics</footer>')
    out.append(f'<script>{_HTML_JS}</script>')
    out.append('</div></body></html>')
    return "\n".join(out)


# ════════════════════════════════════════════════════════════════════
# JSON Output (machine-readable; the foundation other tools build on)
# ════════════════════════════════════════════════════════════════════

def build_result_model(results: list[dict], cfg: dict, pg_version: str,
                       ai_analysis: str | None = None,
                       include_raw: bool | None = None) -> dict:
    """Assemble the canonical, serializable result model.

    This is the single structured representation of a run. ``generate_json``
    serializes it verbatim and ``generate_prometheus`` derives metrics from it,
    so both formats stay in lock-step with the Markdown/HTML reports.
    """
    if include_raw is None:
        include_raw = cfg.get("include_raw_output", True)

    score = compute_score(results)
    letter, label, _ = grade_for(score)

    status_counts = {"clear": 0, "findings": 0, "error": 0}
    areas: dict[str, dict[str, int]] = {}
    sections: list[dict] = []

    for r in results:
        meta   = SECTION_META.get(r["num"], {})
        area   = meta.get("area", "Other")
        risk   = meta.get("risk", "info")
        status = section_status(r["badge"])
        status_counts[status] += 1

        a = areas.setdefault(area, {"clear": 0, "findings": 0, "error": 0})
        a[status] += 1

        rows = None if status == "error" else (count_rows(r["stdout"]) or 0)

        section: dict[str, Any] = {
            "num": r["num"],
            "file": r["file"],
            "title": r["title"],
            "area": area,
            "risk": risk,
            "status": status,
            "rows": rows,
            "header": r.get("header") or {},
            "error": error_analysis(r["stderr"]) if status == "error" else None,
        }
        if include_raw:
            section["raw"] = r["stdout"] if status != "error" else r["stderr"]
        sections.append(section)

    return {
        "schema_version": JSON_SCHEMA_VERSION,
        "tool": "pgvitals",
        "tool_version": PGVITALS_VERSION,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "database": {
            "name": cfg.get("database"),
            "host": cfg.get("host"),
            "port": cfg.get("port"),
            "user": cfg.get("user"),
            "server_version": pg_version,
        },
        "score": {"value": score, "grade": letter, "label": label},
        "summary": {
            "sections": len(results),
            "clear": status_counts["clear"],
            "findings": status_counts["findings"],
            "error": status_counts["error"],
        },
        "areas": areas,
        "sections": sections,
        "ai_analysis": ai_analysis,
    }


def generate_json(results: list[dict], cfg: dict, pg_version: str,
                  ai_analysis: str | None = None) -> str:
    """Serialize the run as pretty-printed JSON (UTF-8, stable key order)."""
    model = build_result_model(results, cfg, pg_version, ai_analysis)
    return json.dumps(model, indent=2, ensure_ascii=False)


# ════════════════════════════════════════════════════════════════════
# Prometheus Output (text exposition format; textfile-collector friendly)
# ════════════════════════════════════════════════════════════════════

def _prom_escape(value: str) -> str:
    """Escape a Prometheus label value per the exposition format spec."""
    return (
        str(value)
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
    )


def _prom_labels(pairs: dict[str, Any]) -> str:
    """Render an ordered ``{k="v",...}`` label set, skipping None values."""
    parts = [f'{k}="{_prom_escape(v)}"' for k, v in pairs.items() if v is not None]
    return "{" + ",".join(parts) + "}"


def generate_prometheus(results: list[dict], cfg: dict, pg_version: str,
                        ai_analysis: str | None = None) -> str:
    """Render the run as Prometheus text exposition format.

    Designed for the node_exporter **textfile collector** (write to a
    ``*.prom`` file) or a Pushgateway, turning a one-shot diagnostic run into a
    scrapeable, alertable signal. ``risk`` is a label so you can alert on, e.g.,
    ``pgvitals_section_findings{risk="critical"} > 0``.
    """
    model = build_result_model(results, cfg, pg_version, ai_analysis, include_raw=False)
    db = model["database"]["name"]
    out: list[str] = []

    def metric(name: str, help_text: str, mtype: str, samples: list[tuple[str, Any]]) -> None:
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} {mtype}")
        for labels, value in samples:
            out.append(f"{name}{labels} {value}")

    base = {"database": db}

    metric("pgvitals_up",
           "1 when a pgvitals run completed and produced this output.",
           "gauge", [(_prom_labels(base), 1)])

    metric("pgvitals_info",
           "Static run metadata (value is always 1).", "gauge",
           [(_prom_labels({
               "database": db,
               "host": model["database"]["host"],
               "server_version": pg_version,
               "tool_version": model["tool_version"],
               "schema_version": model["schema_version"],
           }), 1)])

    metric("pgvitals_health_score",
           "Overall pgvitals health score (0-100).", "gauge",
           [(_prom_labels(base), model["score"]["value"])])

    metric("pgvitals_health_grade",
           "Health grade as an info metric (value is always 1).", "gauge",
           [(_prom_labels({"database": db,
                           "grade": model["score"]["grade"],
                           "label": model["score"]["label"]}), 1)])

    metric("pgvitals_sections",
           "Section counts by execution status.", "gauge",
           [(_prom_labels({**base, "status": s}), model["summary"][s])
            for s in ("clear", "findings", "error")]
           + [(_prom_labels({**base, "status": "total"}), model["summary"]["sections"])])

    up_samples: list[tuple[str, Any]] = []
    find_samples: list[tuple[str, Any]] = []
    for s in model["sections"]:
        seclabels = _prom_labels({
            "database": db, "section": s["num"],
            "area": s["area"], "risk": s["risk"], "title": s["title"],
        })
        up_samples.append((seclabels, 0 if s["status"] == "error" else 1))
        if s["status"] != "error":
            find_samples.append((seclabels, s["rows"]))

    metric("pgvitals_section_up",
           "1 if the section executed, 0 if it errored / was unavailable.",
           "gauge", up_samples)
    metric("pgvitals_section_findings",
           "Number of finding rows a section returned (0 = clear).",
           "gauge", find_samples)

    return "\n".join(out) + "\n"


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
  python run_diagnostics.py --format json -o out.json # Machine-readable output
  python run_diagnostics.py --format prometheus       # Prometheus exposition (.prom)
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
    g3.add_argument("--format", choices=["markdown", "html", "json", "prometheus"],
                    help="Report format: markdown (default), html, json, or prometheus")
    g3.add_argument("--no-raw", action="store_true", help="Omit raw query output from report")
    g3.add_argument("--explain", action="store_true",
                    help="Add an AI analysis of the findings (requires ANTHROPIC_API_KEY)")
    g3.add_argument("--explain-model", help="Model for --explain (default: claude-sonnet-4-6)")

    p.add_argument("--selftest", action="store_true",
                   help="Run offline format self-tests (no database) and exit")

    return p.parse_args()


def _selftest() -> int:
    """Exercise every output formatter against synthetic results — no DB needed.

    Validates that JSON parses and carries the expected shape, and that the
    Prometheus output is well-formed exposition text. Wired into CI.
    """
    results = [
        {"num": "01", "file": "01_slow_queries.sql", "title": "Slow Queries",
         "header": {"What": "x", "Action": "tune"}, "stdout": "row\n(3 rows)",
         "stderr": "", "rc": 0, "badge": "📊 Data"},
        {"num": "07", "file": "07_duplicate_indexes.sql", "title": "Duplicate Indexes",
         "header": {}, "stdout": "(0 rows)", "stderr": "", "rc": 0, "badge": "✅ Clear"},
        {"num": "26", "file": "26_xid_wraparound.sql", "title": "Xid Wraparound",
         "header": {"Action": "VACUUM"}, "stdout": "danger\n(1 row)",
         "stderr": "", "rc": 0, "badge": "📊 Data"},
        {"num": "36", "file": "36_pg_stat_io.sql", "title": "Pg Stat Io",
         "header": {}, "stdout": "",
         "stderr": "ERROR:  relation \"pg_stat_io\" does not exist",
         "rc": 1, "badge": "⚠️ Error"},
    ]
    cfg = {"database": "selftest", "host": "localhost", "port": 5432,
           "user": "postgres", "include_raw_output": True}
    pg_version = "16.2"
    failures: list[str] = []

    # Markdown + HTML must not raise and must be non-empty.
    for name, fn in (("markdown", generate_report), ("html", generate_html_report)):
        text = fn(results, cfg, pg_version)
        if not text or len(text) < 50:
            failures.append(f"{name}: empty/too short")

    # JSON: parses, correct counts, no raw leakage rules.
    doc = json.loads(generate_json(results, cfg, pg_version))
    if doc["schema_version"] != JSON_SCHEMA_VERSION:
        failures.append("json: schema_version mismatch")
    if doc["summary"] != {"sections": 4, "clear": 1, "findings": 2, "error": 1}:
        failures.append(f"json: bad summary {doc['summary']}")
    if doc["score"]["value"] != compute_score(results):
        failures.append("json: score mismatch")
    sec01 = next(s for s in doc["sections"] if s["num"] == "01")
    if sec01["rows"] != 3 or sec01["status"] != "findings":
        failures.append(f"json: section 01 wrong {sec01['rows']}/{sec01['status']}")
    if next(s for s in doc["sections"] if s["num"] == "36")["rows"] is not None:
        failures.append("json: error section should have null rows")

    # Prometheus: parseable lines, expected metric names, label escaping intact.
    prom = generate_prometheus(results, cfg, pg_version)
    plines = [ln for ln in prom.splitlines() if ln and not ln.startswith("#")]
    for ln in plines:
        if " " not in ln or not re.match(r"^[a-zA-Z_][a-zA-Z0-9_]*(\{.*\})? -?\d", ln):
            failures.append(f"prometheus: malformed line: {ln}")
            break
    needed = ["pgvitals_up", "pgvitals_health_score", "pgvitals_section_findings",
              "pgvitals_section_up", "pgvitals_info", "pgvitals_sections"]
    for m in needed:
        if not any(ln.startswith(m) for ln in plines):
            failures.append(f"prometheus: missing metric {m}")
    if f'pgvitals_health_score{{database="selftest"}} {compute_score(results)}' not in prom:
        failures.append("prometheus: health_score line missing/incorrect")

    if failures:
        print("SELFTEST FAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"pgvitals format self-test passed "
          f"(markdown, html, json, prometheus; score={compute_score(results)})")
    return 0


def main() -> int:
    args = parse_args()

    if args.selftest:
        return _selftest()

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
    if args.format:     cfg["format"]            = args.format

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

    # ── Optional AI analysis ────────────────────────────────────────
    ai_analysis = None
    if args.explain:
        sys.path.insert(0, str(SCRIPT_DIR))
        try:
            from explain import explain as _run_explain
        except Exception as e:  # noqa: BLE001
            print(f"⚠  --explain unavailable: could not load explain module ({e})")
            _run_explain = None
        if _run_explain:
            if not os.environ.get("ANTHROPIC_API_KEY"):
                print("⚠  --explain requested but ANTHROPIC_API_KEY is not set — skipping AI analysis.")
            else:
                print("🧠 Generating AI analysis...", end=" ", flush=True)
                ai_analysis = _run_explain(results, cfg, pg_version,
                                           model=args.explain_model,
                                           section_meta=SECTION_META)
                print("done" if ai_analysis else "skipped")
                print()

    # ── Generate report ─────────────────────────────────────────────
    fmt = cfg.get("format", "markdown")
    if fmt == "html":
        report = generate_html_report(results, cfg, pg_version, ai_analysis)
    elif fmt == "json":
        report = generate_json(results, cfg, pg_version, ai_analysis)
    elif fmt == "prometheus":
        report = generate_prometheus(results, cfg, pg_version, ai_analysis)
    else:
        report = generate_report(results, cfg, pg_version, ai_analysis)

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
        # Match the extension to the chosen format
        ext = FORMAT_EXT.get(fmt, ".md")
        if not filename.endswith(ext):
            filename = re.sub(r"\.[^.]+$", "", filename) + ext
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
