open Vitest

external asEntity: 'a => Internal.entity = "%identity"
external value: 'a => unknown = "%identity"

let table = Table.mkTable(
  "items",
  ~fields=[
    Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
    Table.mkField("owner", String, ~isIndex=true, ~fieldSchema=S.string),
    Table.mkField("price", BigDecimal({}), ~isIndex=true, ~fieldSchema=S.string),
    Table.mkField("createdAt", Date, ~isIndex=true, ~fieldSchema=S.string),
    Table.mkField("tag", Bytea, ~isIndex=true, ~fieldSchema=S.string),
    Table.mkField("metadata", Json, ~isIndex=true, ~fieldSchema=S.json(~validate=false)),
  ],
)

let make = () => InMemoryTable.Entity.make(~entityIdToKey=EntityId.unsafeToAny)

let set = (memory, id, entity) =>
  memory->InMemoryTable.Entity.set(
    ~committedCheckpointId=0n,
    Set({entityId: EntityId.unsafeOfString(id), entity: entity->asEntity, checkpointId: 1n}),
  )

let query = (memory, field, operators) => {
  let filter =
    Dict.fromArray([(field, operators)])->EntityFilter.parseOrThrow(~entityName="Item", ~table)
  memory->InMemoryTable.Entity.addEmptyIndex(~filter, ~table)
  let get = memory->InMemoryTable.Entity.getUnsafeOnIndex
  get(filter->EntityFilter.toString(~table))
  ->Array.map(entity => (entity->(Utils.magic: Internal.entity => {"id": string}))["id"])
  ->Array.toSorted(String.compare)
}

let countedEntity: (string, string, unit => unit) => Internal.entity = %raw(`
  (id, owner, onRead) => Object.defineProperty({id}, "owner", {
    enumerable: true,
    get() { onRead(); return owner; }
  })
`)

describe("In-memory equality index construction", () => {
  it("keys equal decimals independently of constructor formatting", t => {
    let memory = make()
    let price = BigDecimal.fromStringUnsafe("1e21")
    let decimalWithPlainFormat: BigDecimal.t => BigDecimal.t = %raw(`value => {
      const Decimal = value.constructor.clone({EXPONENTIAL_AT: 100})
      return new Decimal("1000000000000000000000")
    }`)
    let plainPrice = decimalWithPlainFormat(price)
    set(memory, "a", {"id": "a", "price": price})
    t.expect(query(memory, "price", dict{"_eq": plainPrice->value})).toEqual(["a"])
    let filter =
      dict{"price": dict{"_eq": plainPrice->value}}->EntityFilter.parseOrThrow(
        ~entityName="Item",
        ~table,
      )
    memory->InMemoryTable.Entity.recordLoadedValues(~filter, ~table)
    let equivalent =
      dict{"price": dict{"_eq": price->value}}->EntityFilter.parseOrThrow(
        ~entityName="Item",
        ~table,
      )
    t.expect(memory->InMemoryTable.Entity.isFullyLoaded(~filter=equivalent)).toBe(true)
  })

  it("visits each candidate bucket once for repeated _in values", t => {
    let memory = make()
    let reads = ref(0)
    for i in 0 to 199 {
      let id = i->Int.toString
      set(memory, id, countedEntity(id, "alice", () => reads := reads.contents + 1))
    }
    let matches = query(memory, "owner", dict{"_in": Array.make(~length=200, "alice")->value})
    t.expect(matches->Array.length).toBe(200)
    t.expect(reads.contents < 1000).toBe(true)
  })

  it("matches distinct Date values without rescanning the whole _in list", t => {
    let memory = make()
    let comparisons = ref(0)
    let countedDate: (int, unit => unit) => unknown = %raw(`(time, count) => {
      const date = new Date(time)
      date.getTime = () => { count(); return time }
      return date
    }`)
    let dates = []
    for i in 0 to 199 {
      let date = countedDate(i, () => comparisons := comparisons.contents + 1)
      set(memory, i->Int.toString, {"id": i->Int.toString, "createdAt": date})
      dates->Array.push(date)->ignore
    }
    t.expect(query(memory, "createdAt", dict{"_in": dates->value})->Array.length).toBe(200)
    t.expect(comparisons.contents < 3000).toBe(true)
  })

  it("scans a field once across many distinct equality queries", t => {
    let memory = make()
    let reads = ref(0)
    for i in 0 to 599 {
      let id = i->Int.toString
      set(memory, id, countedEntity(id, `owner-${id}`, () => reads := reads.contents + 1))
    }
    for i in 0 to 299 {
      let id = i->Int.toString
      t.expect(query(memory, "owner", dict{"_eq": `owner-${id}`->value})).toEqual([id])
    }
    // Count field access rather than wall time: a full scan per query reads
    // 180,000 rows, while a shared field index visits 600 plus its matches.
    t.expect(reads.contents <= 1000).toBe(true)
  })

  it("seeds _in and equality indexes from existing rows without duplicates", t => {
    let memory = make()
    set(memory, "a", {"id": "a", "owner": "alice"})
    set(memory, "b", {"id": "b", "owner": "bob"})
    t.expect(query(memory, "owner", dict{"_in": ["alice", "bob", "alice"]->value})).toEqual([
      "a",
      "b",
    ])
    t.expect(query(memory, "owner", dict{"_eq": "bob"->value})).toEqual(["b"])
    t.expect(query(memory, "owner", dict{"_in": []->value})).toEqual([])
  })

  it("updates the shared rows before previously unseen filters are registered", t => {
    let memory = make()
    set(memory, "a", {"id": "a", "owner": "alice"})
    let _ = query(memory, "owner", dict{"_eq": "nobody"->value})
    set(memory, "a", {"id": "a", "owner": "bob"})
    set(memory, "b", {"id": "b", "owner": "bob"})
    memory->InMemoryTable.Entity.set(
      ~committedCheckpointId=0n,
      Delete({entityId: EntityId.unsafeOfString("b"), checkpointId: 1n}),
    )
    t.expect(query(memory, "owner", dict{"_eq": "alice"->value})).toEqual([])
    t.expect(query(memory, "owner", dict{"_eq": "bob"->value})).toEqual(["a"])
  })

  it("does not key nullish columns and removes a value changed to null", t => {
    let memory = make()
    set(memory, "a", {"id": "a", "owner": Nullable.null})
    set(memory, "b", {"id": "b"})
    set(memory, "c", {"id": "c", "owner": "alice"})
    t.expect(query(memory, "owner", dict{"_eq": "alice"->value})).toEqual(["c"])
    set(memory, "c", {"id": "c", "owner": Nullable.null})
    t.expect(query(memory, "owner", dict{"_in": ["alice", "bob"]->value})).toEqual([])
  })

  it("uses the field comparator's keys for dates, bytes and JSON objects", t => {
    let memory = make()
    set(
      memory,
      "a",
      %raw(`({id: "a", createdAt: new Date(1234), tag: new Uint8Array([1, 2]), metadata: {a: 1, b: 2}})`),
    )
    t.expect(query(memory, "createdAt", dict{"_eq": %raw(`new Date(1234)`)})).toEqual(["a"])
    t.expect(query(memory, "tag", dict{"_eq": %raw(`new Uint8Array([1, 2])`)})).toEqual(["a"])
    t.expect(query(memory, "metadata", dict{"_eq": %raw(`({b: 2, a: 1})`)})).toEqual(["a"])
  })

  it("rebuilds field buckets after committed rows are dropped", t => {
    let memory = make()
    set(memory, "a", {"id": "a", "owner": "alice"})
    let _ = query(memory, "owner", dict{"_eq": "alice"->value})
    memory->InMemoryTable.Entity.dropCommittedChanges(
      ~committedCheckpointId=1n,
      ~keepLoadedFromDb=false,
    )
    set(memory, "b", {"id": "b", "owner": "alice"})
    t.expect(query(memory, "owner", dict{"_in": ["alice", "bob"]->value})).toEqual(["b"])
  })

  it("keeps active equality and range indexes consistent while values move", t => {
    let memory = make()
    set(memory, "a", {"id": "a", "owner": "alice"})
    set(memory, "b", {"id": "b", "owner": "bob"})
    let range = dict{"_gte": "alice"->value, "_lt": "carol"->value}
    t.expect(query(memory, "owner", range)).toEqual(["a", "b"])
    let _ = query(memory, "owner", dict{"_in": ["alice", "bob"]->value})
    set(memory, "b", {"id": "b", "owner": "carol"})
    t.expect(query(memory, "owner", range)).toEqual(["a"])
    t.expect(query(memory, "owner", dict{"_in": ["alice", "bob"]->value})).toEqual(["a"])
    t.expect(query(memory, "owner", dict{"_eq": "carol"->value})).toEqual(["b"])
  })

  it("maintains a bucket created by recording loaded values before its first index", t => {
    let memory = make()
    set(memory, "a", {"id": "a", "owner": "alice"})
    let filter =
      dict{"owner": dict{"_in": ["alice", "bob"]->value}}->EntityFilter.parseOrThrow(
        ~entityName="Item",
        ~table,
      )
    memory->InMemoryTable.Entity.recordLoadedValues(~filter, ~table)
    set(memory, "a", {"id": "a", "owner": "bob"})
    t.expect(query(memory, "owner", dict{"_eq": "alice"->value})).toEqual([])
    t.expect(query(memory, "owner", dict{"_eq": "bob"->value})).toEqual(["a"])
  })
})
