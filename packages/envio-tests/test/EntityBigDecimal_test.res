open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: entity-big-decimal
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type EntityWithBigDecimal {
  id: ID!
  bigDecimal: BigDecimal!
}
`,
)

type entityWithBigDecimal = {id: string, bigDecimal: BigDecimal.t}
type entityOps = {set: entityWithBigDecimal => unit}
type handlerContext = {@as("EntityWithBigDecimal") entityWithBigDecimal: entityOps}

describe("Load and save an entity with a BigDecimal from DB", () => {
  scenario->Scenario.it(
    "be able to set and read entities with BigDecimal from DB",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(300)
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 100,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              context.entityWithBigDecimal.set({
                id: "testEntity",
                bigDecimal: BigDecimal.fromFloat(123.456),
              })
              context.entityWithBigDecimal.set({
                id: "testEntity2",
                bigDecimal: BigDecimal.fromFloat(654.321),
              })
            },
          },
        ],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      let entities: array<entityWithBigDecimal> = await indexer.query("EntityWithBigDecimal")

      t.expect(
        entities
        ->Array.map(entity => (entity.id, entity.bigDecimal.toString()))
        ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b)),
      ).toEqual([("testEntity", "123.456"), ("testEntity2", "654.321")])
    },
  )
})

describe("BigDecimal Operations", () => {
  it("BigDecimal add 123.456 + 654.123 = 777.579", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromStringUnsafe("654.123")

    let c = a.plus(b)

    t.expect(c.toString()).toBe("777.579")
  })

  it("minus: 654.321 - 123.123 = 531.198", t => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromStringUnsafe("123.123")

    let result = a.minus(b)

    t.expect(result.toString()).toBe("531.198")
  })

  it("times: 123.456 * 2 = 246.912", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromInt(2)

    let result = a.times(b)

    t.expect(result.toString()).toBe("246.912")
  })

  it("div: 246.912 / 2 = 123.456", t => {
    let a = BigDecimal.fromFloat(246.912)
    let b = BigDecimal.fromInt(2)

    let result = a.div(b)

    t.expect(result.toString()).toBe("123.456")
  })

  it("equals: 123.456 == 123.456", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(123.456)

    let result = a.isEqualTo(b)

    t.expect(result).toBe(true)
  })

  it("gt: 654.321 > 123.456", t => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromFloat(123.456)

    let result = a.gt(b)

    t.expect(result).toBe(true)
  })

  it("gte: 654.321 >= 654.321", t => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromFloat(654.321)

    let result = a.gte(b)

    t.expect(result).toBe(true)
  })

  it("lt: 123.456 < 654.321", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(654.321)

    let result = a.lt(b)

    t.expect(result).toBe(true)
  })

  it("lte: 123.456 <= 123.456", t => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(123.456)

    let result = a.lte(b)

    t.expect(result).toBe(true)
  })
})
