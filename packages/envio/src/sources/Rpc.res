let makeRpcRoute = (method: string, paramsSchema, resultSchema) => {
  let idSchema = S.literal(1)
  let versionSchema = S.literal("2.0")
  Rest.route(() => {
    method: Post,
    path: "",
    input: s => {
      let _ = s.field("method", S.literal(method))
      let _ = s.field("id", idSchema)
      let _ = s.field("jsonrpc", versionSchema)
      s.field("params", paramsSchema)
    },
    responses: [
      s => {
        let _ = s.field("jsonrpc", versionSchema)
        let _ = s.field("id", idSchema)
        s.field("result", resultSchema)
      },
    ],
  })
}

type hex = string
let makeHexSchema = fromStr =>
  S.string->S.transform(s => {
    parser: str =>
      switch str->fromStr {
      | Some(v) => v
      | None => s.fail("The string is not valid hex")
      },
    serializer: value => value->Viem.toHex->(Utils.magic: EvmTypes.Hex.t => 'a),
  })

external number: string => int = "Number"
let hexIntSchema: S.schema<int> = makeHexSchema(v => v->number->Some)
