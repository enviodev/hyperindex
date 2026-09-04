# subgraph_test

An unmodified subgraph project, indexed by HyperIndex. There is no `config.yaml`
and nothing envio-shaped in the project: `subgraph.yaml` is the config, and the
CLI picks it up because no `config.yaml` sits beside it.

It covers a factory, a template created by `dataSource.create`, a contract call,
and a block handler.

`generated/` is real `graph codegen` output, checked in rather than gitignored
so the mappings run against the same bytes a subgraph developer gets:

    @graphprotocol/graph-cli 0.98.1
    @graphprotocol/graph-ts  0.38.1

Regenerate it by installing that graph-cli in this directory and running
`graph codegen`. Nothing in the test run needs graph-cli, so it isn't a
dependency here.

## Type checking

`tsc` cannot check these mappings, and neither `graph codegen` nor `graph build`
asks it to: `@graphprotocol/graph-ts` is AssemblyScript source, and its `u64`,
`i32` and `usize` annotations are not TypeScript types. A subgraph project is
type-checked by `asc`, through `graph build`.
