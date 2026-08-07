open Vitest

// State-machine fuzz over FetchState's public API, driven the way ChainState
// drives it in production: ticks with the density-capped budget, responses
// landing out of order and partially, dynamic registrations arriving from
// responses, and occasional sibling-triggered rollbacks.
//
// Hunts the chain-42161 freeze on 3.5.1: a partition left with a pending query
// that no response will ever clear (a "ghost") starves the whole chain —
// its reservation eats the density-capped budget in acceptCandidates every
// tick, and its unfetched entry pins isFetching so merge retirement never
// runs, freezing bufferBlockNumber.
//
// Invariants checked after every op:
// - no partition holds two pending queries with the same fromBlock (responses
//   are matched by fromBlock, so a duplicate leaves an eternal ghost)
// - with nothing in flight and a partition behind the head, a tick with the
//   production budget formula must produce a query (no silent freeze)
// - at quiescence every pending query has cleared

let mulberry32: int => (unit => float) = %raw(`(seed) => {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}`)

let contractNames = ["Gravatar", "NftFactory"]

let makeAddress = (rng: unit => float) => {
  let hex = "0123456789abcdef"
  let chars = Array.fromInitializer(~length=40, _ =>
    hex->String.charAt((rng() *. 16.)->Float.toInt)
  )
  ("0x" ++ chars->Array.join(""))->Address.Evm.fromStringOrThrow
}

type run = {
  mutable fetchState: FetchState.t,
  addressStore: AddressStore.t,
  mutable knownHeight: int,
  mutable pendingBudget: float,
  inFlight: array<FetchState.query>,
  density: float,
  opLog: array<string>,
}

let log = (run, op) => {
  run.opLog->Array.push(op)->ignore
  if run.opLog->Array.length > 60 {
    run.opLog->Array.shift->ignore
  }
}

let partitions = (run: run) =>
  run.fetchState.optimizedPartitions.entities->Dict.valuesToArray

let minFrontier = (run: run) =>
  run
  ->partitions
  ->Array.reduce(run.knownHeight, (min, p) =>
    p.latestFetchedBlock.blockNumber < min ? p.latestFetchedBlock.blockNumber : min
  )

let describePartitions = (run: run) =>
  run
  ->partitions
  ->Array.map(p =>
    `{id:${p.id} lfb:${p.latestFetchedBlock.blockNumber->Int.toString} merge:${switch p.mergeBlock {
      | Some(m) => m->Int.toString
      | None => "-"
      }} dyn:${p.dynamicContract->Option.getOr("-")} addrs:${p.addresses
      ->AddressSet.size
      ->Int.toString} depAddrs:${p.selection.dependsOnAddresses ? "y" : "n"} selStart:${switch p.selection.startBlock {
      | Some(s) => s->Int.toString
      | None => "-"
      }} cap:${p.sourceRangeCapacity->Int.toString}/${p.prevSourceRangeCapacity->Int.toString} dens:${switch p.eventDensity {
      | Some(d) => d->Float.toString
      | None => "-"
      }} pending:[${p.mutPendingQueries
      ->Array.map(pq =>
        `${pq.fromBlock->Int.toString}..${switch pq.toBlock {
          | Some(t) => t->Int.toString
          | None => "∞"
          }}${pq.fetchedBlock === None ? "?" : "!"}`
      )
      ->Array.join(",")}]}`
  )
  ->Array.join(" ")

let fail = (run, ~seed, ~message) =>
  JsError.throwWithMessage(
    `${message} (seed ${seed->Int.toString}, height ${run.knownHeight->Int.toString})\n` ++
    `partitions: ${run->describePartitions}\n` ++
    `ops: ${run.opLog->Array.join(" | ")}`,
  )

// Mirrors ChainState.getNextQuery's target and density-capped budget. Returns
// the number of queries dispatched.
let tick = (run: run, ~waterfall=5000.) => {
  let buffer = run.fetchState->FetchState.bufferBlockNumber
  let ceiling = run.knownHeight
  let target = if run.density *. (ceiling - buffer)->Int.toFloat <= waterfall {
    ceiling
  } else {
    buffer + Math.ceil(waterfall /. run.density)->Float.toInt
  }
  let rangeCost = run.density *. (target - buffer)->Int.toFloat
  let budget = Pervasives.min(waterfall, Math.ceil(rangeCost) +. run.pendingBudget)
  switch run.fetchState->FetchState.getNextQuery(
    ~chainTargetBlock=target,
    ~chainTargetItems=budget,
  ) {
  | Ready(queries) =>
    run.fetchState->FetchState.startFetchingQueries(~queries)
    queries->Array.forEach(q => {
      run.pendingBudget = run.pendingBudget +. q.itemsEst->Int.toFloat
      run.inFlight->Array.push(q)->ignore
      run->log(`q p${q.partitionId}@${q.fromBlock->Int.toString}`)
    })
    queries->Array.length
  | WaitingForNewBlock =>
    run->log("wait")
    0
  | NothingToQuery =>
    run->log("idle")
    0
  }
}

let respond = (run: run, ~rng, ~index) => {
  let q = run.inFlight->Array.getUnsafe(index)
  run.inFlight->Array.splice(~start=index, ~remove=1, ~insert=[])->ignore
  let upper = Pervasives.min(q.toBlock->Option.getOr(run.knownHeight), run.knownHeight)
  let upper = Pervasives.max(upper, q.fromBlock)
  let latest = q.fromBlock + (rng() *. (upper - q.fromBlock + 1)->Int.toFloat)->Float.toInt
  let latest = Pervasives.min(latest, upper)
  // A response occasionally registers dynamic contracts, applied before the
  // response the way ChainState.handleQueryResult does.
  if rng() < 0.15 {
    let contractName =
      contractNames->Array.getUnsafe((rng() *. 2.)->Float.toInt)
    let registrationBlock =
      q.fromBlock + (rng() *. (latest - q.fromBlock + 1)->Int.toFloat)->Float.toInt
    run.fetchState =
      run.fetchState->FetchState.registerDynamicContracts(
        ~addressStore=run.addressStore,
        ~claimCeiling=Pervasives.max(run.knownHeight, latest),
        [
          {
            address: makeAddress(rng),
            contractName,
            registrationBlock,
          },
        ],
      )
    run->log(`reg ${contractName}@${registrationBlock->Int.toString}`)
  }
  run.fetchState =
    run.fetchState->FetchState.handleQueryResult(
      ~query=q,
      ~latestFetchedBlock={blockNumber: latest, blockTimestamp: 0},
      ~newItems=[],
    )
  run.pendingBudget = Pervasives.max(0., run.pendingBudget -. q.itemsEst->Int.toFloat)
  run->log(`r p${q.partitionId}@${q.fromBlock->Int.toString}->${latest->Int.toString}`)
}

let checkInvariants = (run: run, ~seed, ~rng) => {
  run
  ->partitions
  ->Array.forEach(p => {
    let seen = Utils.Set.make()
    p.mutPendingQueries->Array.forEach(pq => {
      if seen->Utils.Set.has(pq.fromBlock) {
        run->fail(
          ~seed,
          ~message=`partition ${p.id} holds two pending queries at fromBlock ${pq.fromBlock->Int.toString}`,
        )
      }
      seen->Utils.Set.add(pq.fromBlock)->ignore
    })
  })
  // With nothing in flight and a partition behind the head, a production tick
  // must dispatch. Land whatever the probe started so the check leaves the run
  // with an empty in-flight set and later ops keep their intended coverage.
  if run.inFlight->Utils.Array.isEmpty && run->minFrontier < run.knownHeight {
    if run->tick === 0 {
      run->fail(~seed, ~message="chain is frozen: behind the head with budget but no query")
    }
    while !(run.inFlight->Utils.Array.isEmpty) {
      run->respond(~rng, ~index=0)
    }
  }
}

let runSeed = (~seed, ~ops) => {
  let rng = mulberry32(seed)
  let onEventRegistrations = [
    (MockIndexer.evmOnEventRegistration(~id="0", ~contractName="Gravatar") :> Internal.onEventRegistration),
    (MockIndexer.evmOnEventRegistration(~id="1", ~contractName="NftFactory") :> Internal.onEventRegistration),
  ]
  let addresses = [
    {
      Internal.address: Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow,
      contractName: "Gravatar",
      registrationBlock: -1,
    },
  ]
  let addressStore = TestAddresses.makeStore(~onEventRegistrations, ~addresses)
  let run = {
    fetchState: FetchState.make(
      ~onEventRegistrations,
      ~addressStore,
      ~addresses,
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=2,
      ~maxOnBlockBufferSize=5000,
      ~chainId=1->ChainId.fromInt,
      ~knownHeight=0,
    ),
    addressStore,
    knownHeight: 100,
    pendingBudget: 0.,
    inFlight: [],
    // Sparse chains decay the density EMA toward zero; sample the low range
    // where the budget cap sits at ~1 item per tick.
    density: Math.pow(10., ~exp=-1. -. rng() *. 5.),
    opLog: [],
  }
  run.fetchState = run.fetchState->FetchState.updateKnownHeight(~knownHeight=run.knownHeight)

  for _ in 1 to ops {
    let roll = rng()
    if roll < 0.3 {
      // New blocks found.
      run.knownHeight = run.knownHeight + 1 + (rng() *. 10.)->Float.toInt
      run.fetchState = run.fetchState->FetchState.updateKnownHeight(~knownHeight=run.knownHeight)
      run->log(`h${run.knownHeight->Int.toString}`)
    } else if roll < 0.6 {
      let _ = run->tick
    } else if roll < 0.95 || run.inFlight->Utils.Array.isEmpty {
      if !(run.inFlight->Utils.Array.isEmpty) {
        run->respond(~rng, ~index=(rng() *. run.inFlight->Array.length->Int.toFloat)->Float.toInt)
      } else {
        let _ = run->tick
      }
    } else {
      // A reorg on a sibling chain: in-flight responses get stale-dropped, the
      // budget and pending queries reset, and the fetch state rolls back.
      run.inFlight->Utils.Array.clearInPlace
      run.pendingBudget = 0.
      run.fetchState = run.fetchState->FetchState.resetPendingQueries
      let upper = Pervasives.max(run->minFrontier, 1)
      let target = (rng() *. upper->Int.toFloat)->Float.toInt
      run.fetchState =
        run.fetchState->FetchState.rollback(
          ~addressStore=run.addressStore,
          ~targetBlockNumber=target,
        )
      run->log(`rollback->${target->Int.toString}`)
    }
    run->checkInvariants(~seed, ~rng)
  }

  // Drain: land every response, then keep ticking and responding until the
  // chain goes quiet. A pending query that never clears, or a frontier that
  // can't reach the head, is the freeze.
  let attempts = ref(0)
  while (
    (!(run.inFlight->Utils.Array.isEmpty) || run->minFrontier < run.knownHeight) &&
      attempts.contents < 500
  ) {
    attempts := attempts.contents + 1
    while !(run.inFlight->Utils.Array.isEmpty) {
      run->respond(~rng, ~index=0)
    }
    let _ = run->tick(~waterfall=100000.)
  }
  if run->minFrontier < run.knownHeight {
    let probe = (~target, ~budget) =>
      switch run.fetchState->FetchState.getNextQuery(
        ~chainTargetBlock=target,
        ~chainTargetItems=budget,
      ) {
      | Ready(queries) =>
        `Ready(${queries
          ->Array.map(q => `p${q.partitionId}@${q.fromBlock->Int.toString}`)
          ->Array.join(",")})`
      | WaitingForNewBlock => "Wait"
      | NothingToQuery => "Nothing"
      }
    run->fail(
      ~seed,
      ~message=`drain could not bring the chain to the head; probes: ` ++
      `head/100k=${probe(~target=run.knownHeight, ~budget=100000.)} ` ++
      `head/1=${probe(~target=run.knownHeight, ~budget=1.)} ` ++
      `buffer+1/100k=${probe(~target=run->minFrontier + 1, ~budget=100000.)}`,
    )
  }
  run
  ->partitions
  ->Array.forEach(p => {
    if p.mutPendingQueries->Array.some(pq => pq.fetchedBlock === None) {
      run->fail(~seed, ~message=`partition ${p.id} still holds an unfetched pending query`)
    }
  })
}

describe("FetchState state-machine fuzz", () => {
  it("keeps every partition fetchable through random ticks, responses, registrations and rollbacks", _t => {
    for seed in 1 to 300 {
      runSeed(~seed, ~ops=250)
    }
  })
})
