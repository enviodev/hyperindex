module Float = {
  @genType
  type t = float

  let schema = S.float
}

// Schema allows parsing strings or numbers to ints
// this is needed for entity_history field where we on the first copy we encode all numbers as strings
// to avoid loss of precision. Otherwise we always serialize to int
module Int = {
  @genType
  type t = int

  external fromStringUnsafe: string => int = "Number"

  let schema = S.union([
    S.int,
    S.string->S.transform(_s => {
      parser: string => string->fromStringUnsafe,
      serializer: Utils.magic,
    }),
  ])->S.setName("GqlDbCustomTypes.Int")
}
