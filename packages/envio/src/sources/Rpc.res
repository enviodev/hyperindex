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

external number: string => int = "Number"
let hexIntSchema: S.schema<int> = S.string->S.transform(_ => {
  parser: str => str->number,
  serializer: value => value->Viem.toHex->(Utils.magic: EvmTypes.Hex.t => 'a),
})
