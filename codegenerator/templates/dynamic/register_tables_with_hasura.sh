# Note, this is a "low fi" solution to get things to work while we haven't settled on any migrations management.
#       only implemented like this until we have chance to discuss a more pollished solution.

# NOTE: This is very brittle code, it will break if the password, hasura url or database changes.
#       Good to see the API though, we could write this in code to be more robust once things have settled a bit more.

# Source: https://hasura.io/docs/latest/api-reference/metadata-api/table-view/#metadata-pg-track-table

{{#each entities as |entity|}}
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
  "type": "pg_track_table",
  "args": {
    "source": "public",
    "schema": "public",
    "name": "{{entity.name.uncapitalized}}"
  }
}'
{{/each}}
# reference: https://hasura.io/docs/latest/api-reference/metadata-api/permission/#metadata-pg-create-select-permission

{{#each entities as |entity|}}
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_select_permission",
    "args": {
        "table": "{{entity.name.uncapitalized}}",
        "role": "public",
        "source": "default",
        "permission": {
            "columns": "*",
            "filter": {}
        }
    }
}'
{{/each}}
