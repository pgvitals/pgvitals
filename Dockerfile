# pgvitals — zero-install PostgreSQL diagnostics in a container.
#
#   docker run --rm -e PGPASSWORD=secret ghcr.io/pgvitals/pgvitals \
#     --host db.example.com --user dba --database prod
#
# Save an HTML report to the host:
#   docker run --rm -e PGPASSWORD=secret -v "$PWD:/out" ghcr.io/pgvitals/pgvitals \
#     --host db.example.com --user dba --database prod \
#     --format html --output /out/report.html
#
# The image bundles the SQL sections, so no `pgvitals init` is needed.
FROM python:3.12-slim

LABEL org.opencontainers.image.title="pgvitals" \
      org.opencontainers.image.description="Copy-paste PostgreSQL diagnostic queries with a health score and report runner." \
      org.opencontainers.image.source="https://github.com/pgvitals/pgvitals" \
      org.opencontainers.image.licenses="MIT"

# psql is the only runtime dependency (the runner shells out to it).
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

# Run the diagnostic runner directly — it resolves sql/ relative to its own
# location (/app/sql), so diagnostics work out of the box.
ENTRYPOINT ["python", "runner/run_diagnostics.py"]
CMD ["--help"]
