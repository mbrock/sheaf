#!/usr/bin/env bash
set -euo pipefail

workspace_graph="https://less.rest/sheaf/workspace"
dataset="${SHEAF_SPARQL_DATASET:?SHEAF_SPARQL_DATASET is required}"
user="${SHEAF_SPARQL_USERNAME:?SHEAF_SPARQL_USERNAME is required}"
password="${SHEAF_SPARQL_PASSWORD:?SHEAF_SPARQL_PASSWORD is required}"
query_endpoint="${dataset%/}/sparql"
update_endpoint="${dataset%/}/update"

count_query='SELECT (COUNT(*) AS ?triples) WHERE { ?s ?p ?o }'

workspace_count_query=$(cat <<SPARQL
SELECT (COUNT(*) AS ?triples) WHERE {
  GRAPH <$workspace_graph> {
    ?s ?p ?o .
  }
}
SPARQL
)

move_update=$(cat <<SPARQL
INSERT {
  GRAPH <$workspace_graph> {
    ?s ?p ?o .
  }
}
WHERE {
  ?s ?p ?o .
};

DELETE {
  ?s ?p ?o .
}
WHERE {
  ?s ?p ?o .
}
SPARQL
)

count() {
  local query="$1"

  curl -fsS \
    -u "$user:$password" \
    -H 'Accept: application/sparql-results+json' \
    --data-urlencode "query=$query" \
    "$query_endpoint" |
    jq -r '.results.bindings[0].triples.value'
}

default_before="$(count "$count_query")"
workspace_before="$(count "$workspace_count_query")"

printf 'Default graph triples before:  %s\n' "$default_before"
printf 'Workspace graph triples before: %s\n' "$workspace_before"

curl -fsS \
  -u "$user:$password" \
  --data-urlencode "update=$move_update" \
  "$update_endpoint" \
  >/dev/null

default_after="$(count "$count_query")"
workspace_after="$(count "$workspace_count_query")"

printf 'Default graph triples after:   %s\n' "$default_after"
printf 'Workspace graph triples after:  %s\n' "$workspace_after"
