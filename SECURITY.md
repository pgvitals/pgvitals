# Security Policy

## Supported Versions

pgvitals is a collection of read-only diagnostic SQL queries. There are no releases with version-specific security fixes — all queries in `main` are current.

## Reporting a Vulnerability

If you discover a query that could expose sensitive data beyond what the `pg_monitor` role is intended to see, or that could be exploited to cause unintended side effects, please report it privately:

1. **Do not open a public GitHub issue.**
2. Email the maintainers or use [GitHub's private vulnerability reporting](https://github.com/pgvitals/pgvitals/security/advisories/new).
3. Include the section number, the query, PostgreSQL version, and a description of the concern.

We will respond within 72 hours and coordinate a fix before any public disclosure.

## Security Notes

- All queries in `sql/` are **read-only** — no `INSERT`, `UPDATE`, `DELETE`, or DDL.
- The monitoring schema (`monitoring/`) creates tables and a function in the `perf_monitor` schema. Review it before running in a shared environment.
- The minimum required privilege is the `pg_monitor` built-in role (PostgreSQL 10+). Superuser is not required for any query.
- Queries surface internal PostgreSQL catalog data. Do not expose their output to untrusted parties — it includes query text, usernames, IP addresses, and schema details.
