open Vitest

@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"

let templateDir = "../cli/templates/static/svm_metaplex_template/typescript"
let read = name => readFileSync(templateDir ++ "/" ++ name, "utf8")

describe("The Metaplex init template", () => {
  // `envio init` copies these files verbatim into a new project, and nothing
  // else in the repo compiles them together. Without this, a change to codegen
  // or to the shipped IDL only surfaces when a user scaffolds the template.
  it("typechecks against its own config, schema and IDL", _ =>
    InternalTestIndexer.fromUserApi(
      ~configYaml=read("config.yaml"),
      ~schema=read("schema.graphql"),
      ~files=Dict.fromArray([
        ("idls/token-metadata.codama.json", read("idls/token-metadata.codama.json")),
      ]),
      ~handlers=read("src/handlers/TokenMetadataHandlers.ts"),
    )->ignore
  )
})
