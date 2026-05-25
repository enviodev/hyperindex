---
name: envio-docs
description: >-
  Use when something is unclear, confusing, or not covered by other skills.
  Search and read the latest Envio documentation without leaving the terminal.
metadata:
  managed-by: envio
---

# Envio Documentation Lookup

Two CLI commands give you access to the full Envio docs:

## Search

```bash
envio tools search-docs "your question here"
```

Returns matching page titles, URLs, and snippets.

## Read a page

```bash
envio tools fetch-docs <url>
```

Pass a URL from the search results to get the full page as markdown.

## Workflow

1. `envio tools search-docs "schema @derivedFrom"` — find relevant pages
2. Pick the best URL from the results
3. `envio tools fetch-docs https://docs.envio.dev/docs/HyperIndex/schema` — read it in full
