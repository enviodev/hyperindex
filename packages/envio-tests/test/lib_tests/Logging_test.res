open Vitest

describe("Logging", () => {
  // A logger per query and per event is built whether or not it ever writes,
  // so binding its fields has to cost nothing until a line passes the level.
  it("Serializes a child's fields once, on its first written line", t => {
    let serialized = ref(0)
    let fields = {
      "toJSON": () => {
        serialized := serialized.contents + 1
        {"chainId": 1}
      },
    }
    let logger = Logging.capture()
    logger->Logging.setLevel(#info)
    let child = logger->Logging.child(fields)
    child->Logging.trace("skipped")
    let beforeWriting = serialized.contents
    child->Logging.info("first")
    child->Logging.info("second")
    t.expect((beforeWriting, serialized.contents, logger->Logging.captured)).toEqual((
      0,
      1,
      [
        dict{"level": JSON.String("info"), "msg": JSON.String("first"), "chainId": JSON.Number(1.)},
        dict{
          "level": JSON.String("info"),
          "msg": JSON.String("second"),
          "chainId": JSON.Number(1.),
        },
      ],
    ))
  })

  it("Lets a child's field and a line's param replace what was bound before", t => {
    let logger = Logging.capture()
    logger
    ->Logging.forChain(1->ChainId.fromInt)
    ->Logging.child({"source": "a"})
    ->Logging.child({"source": "b"})
    ->Logging.info("x", ~params={"chainId": 2})
    t.expect(logger->Logging.captured->Array.map(line => line->Dict.toArray)).toEqual([
      [
        ("level", JSON.String("info")),
        ("msg", JSON.String("x")),
        ("chainId", JSON.Number(2.)),
        ("source", JSON.String("b")),
      ],
    ])
  })

  it("Keeps an error's message and stack, and a bigint as a string", t => {
    let logger = Logging.capture()
    let error = JsError.make("boom")
    logger->Logging.info(
      "x",
      ~params={"err": error, "big": 12345678901234567890n, "nested": {"deep": 1n}},
    )
    t.expect(logger->Logging.captured).toEqual([
      dict{
        "level": JSON.String("info"),
        "msg": JSON.String("x"),
        "err": JSON.Object(
          dict{
            "type": JSON.String("Error"),
            "message": JSON.String("boom"),
            "stack": JSON.String(error->JsError.stack->Option.getOr("")),
          },
        ),
        "big": JSON.String("12345678901234567890"),
        "nested": JSON.Object(dict{"deep": JSON.String("1")}),
      },
    ])
  })
})
