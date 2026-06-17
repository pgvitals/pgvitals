#!/usr/bin/env python3
"""AI analysis for pgvitals — turn diagnostic findings into a prioritized,
plain-English action plan via the Anthropic API.

No third-party dependencies: the API call uses the standard-library
``urllib`` (not the anthropic SDK), keeping pgvitals install-free.

Privacy: ``--explain`` transmits the diagnostic findings (section titles,
actions, and truncated query output, plus the database name) to Anthropic.
It is strictly opt-in and does nothing without ANTHROPIC_API_KEY set.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

DEFAULT_MODEL = "claude-sonnet-4-6"
API_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"

SYSTEM_PROMPT = (
    "You are a senior PostgreSQL DBA and performance engineer reviewing the "
    "output of pgvitals diagnostic sections. Write a concise, actionable report "
    "in Markdown for the engineer who ran it.\n\n"
    "Rules:\n"
    "- Only call out issues that are actually present in the data. Do not invent findings.\n"
    "- Be specific: cite the section, the observed number, and the concrete fix "
    "(exact SQL or config change) where possible.\n"
    "- Prioritize ruthlessly: lead with what could cause an outage or data loss.\n"
    "- If the database looks healthy, say so briefly rather than padding.\n\n"
    "Structure your reply as:\n"
    "### Summary\n(2-3 sentences on overall health.)\n\n"
    "### Prioritized actions\n"
    "An ordered list, most urgent first. For each: **what & why** (one line) then "
    "the remediation command/SQL.\n\n"
    "### Watch list\n(Optional — lower-priority items to monitor.)"
)


def _truncate(text: str, max_lines: int = 12, max_chars: int = 1200) -> str:
    lines = text.strip().splitlines()
    if len(lines) > max_lines:
        lines = lines[:max_lines] + [f"... (+{len(lines) - max_lines} more rows)"]
    out = "\n".join(lines)
    return out[:max_chars]


def build_user_message(results: list[dict], cfg: dict, pg_version: str,
                       section_meta: dict | None = None) -> str:
    """Build the user-message payload (pure — no network). Includes only
    sections that returned findings or errors, to keep the prompt focused."""
    section_meta = section_meta or {}
    parts = [
        f"Database: {cfg.get('database', '?')}  |  PostgreSQL {pg_version}",
        "",
        "Diagnostic findings (sections with data or errors only):",
        "",
    ]
    n_findings = 0
    for r in results:
        meta = section_meta.get(r["num"], {})
        if r["badge"] == "📊 Data":
            n_findings += 1
            parts.append(f"## {r['num']} {r['title']}  [risk: {meta.get('risk', '?')}]")
            hdr = r.get("header", {})
            if hdr.get("What"):
                parts.append(f"What: {hdr['What']}")
            if hdr.get("Action"):
                parts.append(f"Suggested action: {hdr['Action']}")
            if r.get("stdout"):
                parts.append("Output:")
                parts.append("```")
                parts.append(_truncate(r["stdout"]))
                parts.append("```")
            parts.append("")
        elif r["badge"] == "⚠️ Error":
            parts.append(f"## {r['num']} {r['title']}  [unavailable]")
            parts.append("")

    if n_findings == 0:
        parts.append("(No sections returned findings — all checks are clear.)")

    parts.append("")
    parts.append("Write the prioritized analysis now.")
    return "\n".join(parts)


def call_anthropic(system: str, user: str, model: str, api_key: str,
                   max_tokens: int = 1500, timeout: int = 60) -> str:
    """POST to the Anthropic Messages API via urllib and return the text reply."""
    body = json.dumps({
        "model": model,
        "max_tokens": max_tokens,
        "system": system,
        "messages": [{"role": "user", "content": user}],
    }).encode("utf-8")

    req = urllib.request.Request(
        API_URL,
        data=body,
        method="POST",
        headers={
            "content-type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": ANTHROPIC_VERSION,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        raise RuntimeError(f"Anthropic API error {e.code}: {detail}") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"Network error contacting Anthropic: {e.reason}") from None

    blocks = payload.get("content", [])
    text = "".join(b.get("text", "") for b in blocks if b.get("type") == "text")
    return text.strip()


def explain(results: list[dict], cfg: dict, pg_version: str,
            model: str | None = None, api_key: str | None = None,
            section_meta: dict | None = None) -> str | None:
    """Return a Markdown AI analysis, or None if no API key is configured.

    Never raises: on any API/network failure it returns a short italic note so
    the diagnostic run itself is never broken by the explain step.
    """
    api_key = api_key or os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return None
    user = build_user_message(results, cfg, pg_version, section_meta)
    try:
        return call_anthropic(SYSTEM_PROMPT, user, model or DEFAULT_MODEL, api_key)
    except Exception as e:  # noqa: BLE001 — explain must never break the run
        return f"_AI analysis unavailable: {e}_"


def _selftest() -> int:
    """Offline self-test: exercise the prompt builder with no network."""
    results = [
        {"num": "01", "title": "Slow Queries", "badge": "📊 Data",
         "header": {"What": "Top queries", "Action": "Add indexes"},
         "stdout": "mean_exec_ms\n250.5\n(1 row)", "stderr": ""},
        {"num": "06", "title": "Unused Indexes", "badge": "✅ Clear",
         "header": {}, "stdout": "(0 rows)", "stderr": ""},
        {"num": "36", "title": "Pg Stat Io", "badge": "⚠️ Error",
         "header": {}, "stdout": "", "stderr": "ERROR: ..."},
    ]
    meta = {"01": {"risk": "high"}, "06": {"risk": "medium"}, "36": {"risk": "medium"}}
    msg = build_user_message(results, {"database": "demo"}, "16.3", meta)
    assert "01 Slow Queries" in msg and "[risk: high]" in msg
    assert "Add indexes" in msg and "250.5" in msg
    assert "06 Unused Indexes" not in msg          # clear sections are omitted
    assert "[unavailable]" in msg                  # error section noted
    assert explain(results, {"database": "demo"}, "16.3", api_key=None) is None
    print("explain selftest: OK")
    return 0


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    print("Usage: imported by run_diagnostics.py (--explain), or run with --selftest")
