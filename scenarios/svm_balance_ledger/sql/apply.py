"""Applies a ClickHouse .sql file over the HTTP interface.

ClickHouse's HTTP interface takes one statement per request, so the file is
split on `;` and sent statement by statement. Connection settings come from the
same ENVIO_CLICKHOUSE_* variables the indexer reads.
"""

import os
import re
import sys
import urllib.error
import urllib.request

HOST = os.environ.get("ENVIO_CLICKHOUSE_HOST", "http://localhost:8123").rstrip("/")
USER = os.environ.get("ENVIO_CLICKHOUSE_USERNAME", "default")
PASSWORD = os.environ.get("ENVIO_CLICKHOUSE_PASSWORD", "")
DATABASE = os.environ.get("ENVIO_CLICKHOUSE_DATABASE", "default")


def statements(path):
    sql = open(path).read()
    # Strip whole-line comments so a `;` inside one cannot split a statement.
    body = "\n".join(l for l in sql.splitlines() if not l.lstrip().startswith("--"))
    return [s.strip() for s in body.split(";") if s.strip()]


def main():
    path = sys.argv[1]
    print(f"Applying {os.path.basename(path)} to {HOST} (database {DATABASE})")
    for statement in statements(path):
        name = re.search(r"VIEW\s+(\w+)", statement, re.IGNORECASE)
        print(f"  - {name.group(1) if name else 'statement'}")
        request = urllib.request.Request(
            f"{HOST}/?database={DATABASE}",
            data=statement.encode(),
            headers={"X-ClickHouse-User": USER, "X-ClickHouse-Key": PASSWORD},
        )
        try:
            urllib.request.urlopen(request).read()
        except urllib.error.HTTPError as error:
            sys.exit(f"\n{error.read().decode()}")
    print("Done. The views are ready to query.")


main()
