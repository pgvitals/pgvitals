# 🗺️ pgvitals Roadmap

This roadmap is ordered by dependency and leverage, not by feature size. The guiding
principles:

1. **Trust before traffic** — don't drive attention to a tool people are afraid to run on production.
2. **Build the reusable artifact first** — the HTML report is embedded by the playground, the badge, the AI output, and the SEO pages.
3. **Lower friction before launching** — make first value instant.
4. **Retain, then expand** — turn a one-time run into a habit before widening the surface area.

Status legend: ⬜ not started · 🚧 in progress · ✅ done

---

## Phase 0 — Foundation & Trust ✅
*Cheap, high-credibility, unblocks everything downstream.*

- ✅ **Multi-version CI matrix** — every SQL section runs against PostgreSQL 13–17 in Docker on each push, with a Validate badge. Sections gate by a machine-readable `-- Min-PG:` header. (This surfaced the real compatibility floor: PG 13, not 12.)
- ✅ **Prod-safety guarantee** — README "Safety" section documents the read-only/lock-free guarantee; CI fails on any DML/DDL keyword in `sql/`.

## Phase 1 — The Core Artifact ✅
*The shareable unit everything else reuses.*

- ✅ **Self-contained HTML report** (`pgvitals --format html`) — 0–100 health-score gauge, color-coded collapsible section cards, Print/Save-PDF button. Single file, inline CSS/JS, works from `file://`.

## Phase 2 — Zero-Friction & Passive Distribution ✅
*All reuse the Phase 1 renderer.*

- ✅ **Browser playground** — `/playground.html`: paste `health_score.sql` output, render the card fully client-side (no DB, no install, nothing uploaded).
- ✅ **Health badge** — dependency-free SVG generator (`runner/make_badge.py`) wired into the healthcheck workflow; embeddable from a `badges` branch.
- ✅ **Docker one-liner** — `docker run --rm ghcr.io/pgvitals/pgvitals --host … --database …`, published by `docker.yml`.

## Phase 3 — The AI Differentiator ✅
*Headline feature; nothing in the comparison table does this.*

- ✅ **`pgvitals --explain`** — sends findings to Claude (stdlib `urllib`, no SDK) for a prioritized, plain-English "what's wrong → fix in this order" narrative, embedded in the Markdown/HTML report. Opt-in, requires `ANTHROPIC_API_KEY`, never breaks a run on failure.
  - *Future:* optional tool-use loop so the model can request follow-up sections; pull the MCP server (Phase 6) forward to ride the same channel.

## Phase 4 — Distribution at Scale
*Once the experience is polished.*

- ⬜ **Programmatic SEO** — one landing page per diagnostic section, each embedding an example report.
- ⬜ **GitHub Action in Marketplace** — formalize the health-check template as a listed action.
- ⬜ **Coordinated launch** — Show HN, r/PostgreSQL, `awesome-postgres` PRs, Homebrew formula.

## Phase 5 — Stickiness / Retention
*Turn a one-time run into a habit.*

- ⬜ **Regression mode** — store snapshots (embedded SQLite) and alert when a metric drifts from baseline.
- ⬜ **Auto-remediation output** — emit runnable `REINDEX` / `CREATE INDEX CONCURRENTLY` / `VACUUM` per finding.
- ⬜ **Managed-Postgres mode** — gracefully degrade on RDS / Aurora / Cloud SQL / Neon / Supabase restricted catalogs.

## Phase 6 — Ecosystem Expansion
*Largest surface area; needs a stable core. The MCP server can be pulled forward to Phase 3 to ride the AI wave harder.*

- ⬜ **MCP server** — expose diagnostics as Model Context Protocol tools so Claude / Cursor can run them conversationally.
- ⬜ **TUI** — live-refreshing terminal health dashboard ("k9s for Postgres").
- ⬜ **`.psqlrc` macro pack** — `\pgv slow`, `\pgv locks`, `\pgv health` shortcuts.
- ⬜ **VS Code extension** — run a section from the editor, results inline.
- ⬜ **Fleet mode** — run across many databases into one rollup dashboard.

---

Contributions toward any item are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
