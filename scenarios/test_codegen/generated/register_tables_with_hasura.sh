# Note, this is a "low fi" solution to get things to work while we haven't settled on any migrations management.
#       only implemented like this until we have chance to discuss a more pollished solution.

# NOTE: This is very brittle code, it will break if the password, hasura url or database changes.
#       Good to see the API though, we could write this in code to be more robust once things have settled a bit more.

# Source: https://hasura.io/docs/latest/api-reference/metadata-api/table-view/#metadata-pg-track-table

curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
  "type": "pg_track_table",
  "args": {
    "source": "public",
    "schema": "public",
    "name": "user"
  }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
  "type": "pg_track_table",
  "args": {
    "source": "public",
    "schema": "public",
    "name": "gravatar"
  }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
  "type": "pg_track_table",
  "args": {
    "source": "public",
    "schema": "public",
    "name": "nftcollection"
  }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
  "type": "pg_track_table",
  "args": {
    "source": "public",
    "schema": "public",
    "name": "token"
  }
}'
# reference: https://hasura.io/docs/latest/api-reference/metadata-api/permission/#metadata-pg-create-select-permission

#Do this for the raw events table as well
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
  "type": "pg_track_table",
  "args": {
    "source": "public",
    "schema": "public",
    "name": "raw_events"
  }
}'

#Do this for the dynamic_contract_registry as well
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
  "type": "pg_track_table",
  "args": {
    "source": "public",
    "schema": "public",
    "name": "dynamic_contract_registry"
  }
}'

curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_select_permission",
    "args": {
        "table": "user",
        "role": "public",
        "source": "default",
        "permission": {
            "columns": "*",
            "filter": {}
        }
    }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_select_permission",
    "args": {
        "table": "gravatar",
        "role": "public",
        "source": "default",
        "permission": {
            "columns": "*",
            "filter": {}
        }
    }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_select_permission",
    "args": {
        "table": "nftcollection",
        "role": "public",
        "source": "default",
        "permission": {
            "columns": "*",
            "filter": {}
        }
    }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_select_permission",
    "args": {
        "table": "token",
        "role": "public",
        "source": "default",
        "permission": {
            "columns": "*",
            "filter": {}
        }
    }
}'

#Do this for the raw events table as well
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_select_permission",
    "args": {
        "table": "raw_events",
        "role": "public",
        "source": "default",
        "permission": {
            "columns": "*",
            "filter": {}
        }
    }
}'
#Do this for the dynamic_contract_registry table as well
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_select_permission",
    "args": {
        "table": "dynamic_contract_registry",
        "role": "public",
        "source": "default",
        "permission": {
            "columns": "*",
            "filter": {}
        }
    }
}'

curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_object_relationship",
    "args": {
        "table": "user",
        "name": "gravatarMap",
        "source": "default",
        "using": {
            "manual_configuration" : {
                "remote_table" : "gravatar",
                "column_mapping" : {
                    "gravatar" : "id"
                }
            }
        }
    }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_array_relationship",
    "args": {
        "table": "user",
        "name": "tokensMap",
        "source": "default",
        "using": {
            "manual_configuration" : {
                "remote_table" : "token",
                "column_mapping" : {
                    "tokens" : "id"
                }
            }
        }
    }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_object_relationship",
    "args": {
        "table": "gravatar",
        "name": "ownerMap",
        "source": "default",
        "using": {
            "manual_configuration" : {
                "remote_table" : "user",
                "column_mapping" : {
                    "owner" : "id"
                }
            }
        }
    }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_object_relationship",
    "args": {
        "table": "token",
        "name": "collectionMap",
        "source": "default",
        "using": {
            "manual_configuration" : {
                "remote_table" : "nftcollection",
                "column_mapping" : {
                    "collection" : "id"
                }
            }
        }
    }
}'
curl -X POST localhost:8080/v1/metadata \
  -H "Content-Type: application/json" \
  -H "X-Hasura-Role: admin" \
  -H "X-Hasura-Admin-Secret: testing" \
  -d '{
    "type": "pg_create_object_relationship",
    "args": {
        "table": "token",
        "name": "ownerMap",
        "source": "default",
        "using": {
            "manual_configuration" : {
                "remote_table" : "user",
                "column_mapping" : {
                    "owner" : "id"
                }
            }
        }
    }
}'
