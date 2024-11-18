module Float = {
  @genType
  type t = float

  let schema = S.float->S.setName("GqlDbCustomTypes.Float")
}

module Int = {
  @genType
  type t = int

  let schema = S.int->S.setName("GqlDbCustomTypes.Int")
}
