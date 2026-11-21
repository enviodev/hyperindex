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
    Table.mkField("prices", BigDecimal({}), ~isArray=true, ~isIndex=true, ~fieldSchema=S.string),
    Table.mkField("tags", String, ~isArray=true, ~isIndex=true, ~fieldSchema=S.string),
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

// Instrument the stored snapshot, not the caller's record: set deliberately
// copies top-level values, so an input getter no longer measures query reads.
let countOwnerReads = (memory: InMemoryTable.Entity.t, id, onRead) => {
  let countedChange: (Change.t<Internal.entity>, unit => unit) => Change.t<Internal.entity> = %raw(`
    (change, onRead) => ({...change, entity: new Proxy(change.entity, {
      get(target, key, receiver) {
        if (key === "owner") onRead()
        return Reflect.get(target, key, receiver)
      }
    })})
  `)
  let change = memory.latestEntityChangeById->Dict.getUnsafe(id)
  memory.latestEntityChangeById->Dict.set(id, countedChange(change, onRead))
}

describe("In-memory equality index construction", () => {
  it("preserves BigDecimal RANGE equality for scalar and array filters", t => {
    let memory = make()
    let zero = BigDecimal.fromInt(0)
    let narrowZero: BigDecimal.t => BigDecimal.t = %raw(`value => {
      const Decimal = value.constructor.clone({RANGE: [-1, 100]})
      return new Decimal(0)
    }`)
    let price = narrowZero(zero)
    let candidate = BigDecimal.fromStringUnsafe("0.01")
    t.expect(BigDecimal.equals(price, candidate)).toBe(true)
    set(memory, "a", {"id": "a", "owner": "alice", "price": price, "prices": [price]})
    t.expect(query(memory, "price", dict{"_eq": candidate->value})).toEqual(["a"])
    t.expect(query(memory, "price", dict{"_in": [candidate]->value})).toEqual(["a"])
    t.expect(query(memory, "prices", dict{"_in": [[candidate]]->value})).toEqual(["a"])
    let filter = dict{
      "price": dict{"_in": [candidate]->value},
      "owner": dict{"_eq": "alice"->value},
    }->EntityFilter.parseOrThrow(~entityName="Item", ~table)
    t.expect(
      (filter->EntityFilter.makeMatcher(~table))(
        {"id": "a", "owner": "alice", "price": price}->asEntity,
      ),
    ).toBe(true)
  })

  it("does not inspect a document for an empty _in predicate", t => {
    let reads = ref(0)
    let entity: (unit => unit) => Internal.entity = %raw(`count => ({
      id: "a", owner: "alice", get metadata() { count(); return {a: 1} }
    })`)
    let filter = dict{
      "metadata": dict{"_in": []->value},
      "owner": dict{"_eq": "alice"->value},
    }->EntityFilter.parseOrThrow(~entityName="Item", ~table)
    t.expect(
      (filter->EntityFilter.makeMatcher(~table))(entity(() => reads := reads.contents + 1)),
    ).toBe(false)
    t.expect(reads.contents).toBe(0)
  })

  it("keeps new filters consistent with mutable object fields", t => {
    let memory = make()
    let entity = %raw(`({id: "a", createdAt: new Date(10), tag: new Uint8Array([1]),
      metadata: {x: 1}, tags: ["old"]})`)
    set(memory, "a", entity)
    let stored = (memory->InMemoryTable.Entity.getUnsafe)("a")->Option.getOrThrow
    let isFrozen: 'a => bool = %raw(`value => Object.isFrozen(value)`)
    t.expect(isFrozen(stored)).toBe(true)
    t.expect(isFrozen(entity)).toBe(false)
    t.expect(query(memory, "createdAt", dict{"_eq": Date.fromTime(10.)->value})).toEqual(["a"])
    t.expect(query(memory, "tag", dict{"_eq": %raw(`new Uint8Array([1])`)})).toEqual(["a"])
    t.expect(query(memory, "metadata", dict{"_eq": %raw(`({x: 1})`)})).toEqual(["a"])
    t.expect(query(memory, "tags", dict{"_eq": ["old"]->value})).toEqual(["a"])
    let mutate: 'a => unit = %raw(`entity => {
      entity.createdAt.setTime(20); entity.tag[0] = 2;
      entity.metadata.x = 2; entity.tags[0] = "new";
    }`)
    mutate(entity)
    t.expect(query(memory, "createdAt", dict{"_in": [Date.fromTime(20.)]->value})).toEqual(["a"])
    t.expect(query(memory, "tag", dict{"_eq": %raw(`new Uint8Array([2])`)})).toEqual(["a"])
    t.expect(query(memory, "metadata", dict{"_eq": %raw(`({x: 2})`)})).toEqual(["a"])
    t.expect(query(memory, "tags", dict{"_in": [["new"]]->value})).toEqual(["a"])
  })

  it("snapshots top-level fields without freezing the caller's entity", t => {
    let memory = make()
    let entity = %raw(`({id: "a", owner: "alice"})`)
    set(memory, "a", entity)
    t.expect(query(memory, "owner", dict{"_eq": "alice"->value})).toEqual(["a"])
    let mutate: 'a => unit = %raw(`entity => { entity.owner = "bob" }`)
    mutate(entity)
    t.expect(query(memory, "owner", dict{"_in": ["alice", "nobody"]->value})).toEqual(["a"])
    t.expect(query(memory, "owner", dict{"_eq": "bob"->value})).toEqual([])
    set(memory, "a", entity)
    t.expect(query(memory, "owner", dict{"_eq": "alice"->value})).toEqual([])
    t.expect(query(memory, "owner", dict{"_eq": "bob"->value})).toEqual(["a"])
  })

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
    // Constructor-dependent equality cannot safely reuse a value-key bucket.
    t.expect(memory->InMemoryTable.Entity.isFullyLoaded(~filter=equivalent)).toBe(false)
  })

  it("visits each candidate bucket once for repeated _in values", t => {
    let memory = make()
    let reads = ref(0)
    for i in 0 to 199 {
      let id = i->Int.toString
      set(memory, id, {"id": id, "owner": "alice"})
      countOwnerReads(memory, id, () => reads := reads.contents + 1)
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
      set(memory, id, {"id": id, "owner": `owner-${id}`})
      countOwnerReads(memory, id, () => reads := reads.contents + 1)
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
