module Float = {
  @genType
  type t = float

  external fromStringUnsafe: string => float = "Number"

  let schema = S.union([
    S.float,
    //This is needed to parse entity history json fields
    S.string->S.transform(_s => {
      parser: string => string->fromStringUnsafe,
      serializer: Utils.magic,
    }),
  ])->S.setName("GqlDbCustomTypes.Float")
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
    //This is needed to parse entity history json fields
    S.string->S.transform(_s => {
      parser: string => string->fromStringUnsafe,
      serializer: Utils.magic,
    }),
  ])->S.setName("GqlDbCustomTypes.Int")
}
