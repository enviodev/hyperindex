open Vitest

// The write plans cross a JSON boundary between the CLI that emits them and the
// runtime that executes them. A plan the runtime doesn't understand — a CLI a
// version ahead, or a hand-edited config — has to be rejected at startup naming
// the offending path, not surface as an undefined column on the first event.
let valid = `[
  {
    "table": "accounts",
    "contractName": "ERC20",
    "eventName": "Transfer",
    "id": {"kind": "path", "path": ["params", "to"]},
    "fields": [
      {
        "name": "balance",
        "op": "sum",
        "type": "bigint",
        "expr": {"kind": "negate", "type": "bigint", "expr": {"kind": "path", "path": ["params", "value"]}}
      }
    ]
  }
]`

let failureMessage = source =>
  try {
    let _ = source->JSON.parseOrThrow->MaterializationPlan.parseAllOrThrow
    "parsed"
  } catch {
  | JsExn(exn) => exn->JsExn.message->Option.getOr("no message")
  }

// The union alternatives the message enumerates are the schema itself, so the
// part worth pinning is where the parse gave up.
let failurePath = source =>
  switch failureMessage(source)->String.match(%re("/Failed parsing at ([^.]+)\./")) {
  | Some([_, Some(path)]) => path
  | _ => failureMessage(source)
  }

describe("Materialization plan decoding", () => {
  it("parses a plan into the typed shape the compiler runs", t => {
    t.expect(valid->JSON.parseOrThrow->MaterializationPlan.parseAllOrThrow).toEqual([
      {
        table: "accounts",
        contractName: "ERC20",
        eventName: "Transfer",
        wildcard: false,
        filter: None,
        id: Path(["params", "to"]),
        fields: [
          Sum({
            name: "balance",
            numeric: BigInt,
            expr: Negate(BigInt, Path(["params", "value"])),
          }),
        ],
      },
    ])
  })

  it("points at the plan a newer CLI wrote", t => {
    t.expect({
      "unknownOperator": valid->String.replace(`"kind": "negate"`, `"kind": "_mul"`)->failurePath,
      "unknownFieldOp": valid->String.replace(`"op": "sum"`, `"op": "product"`)->failurePath,
      "unknownNumericType": valid->String.replace(`"type": "bigint"`, `"type": "decimal128"`)
        ->failurePath,
      "missingField": valid->String.replace(`"table": "accounts",`, "")->failurePath,
    }).toEqual({
      "unknownOperator": `["0"]["fields"]["0"]["expr"]`,
      "unknownFieldOp": `["0"]["fields"]["0"]`,
      "unknownNumericType": `["0"]["fields"]["0"]["type"]`,
      "missingField": `["0"]["table"]`,
    })
  })

  it("says which config is stale", t => {
    t.expect(valid->String.replace(`"table": "accounts",`, "")->failureMessage).toBe(
      "Invalid indexer config: the materialization plans don't match this envio version. " ++
      `Failed parsing at ["0"]["table"]. Reason: Expected string, received undefined. ` ++
      "Run `envio codegen` again.",
    )
  })
})
