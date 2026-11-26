open Vitest

// Drives the indexer loop over a mocked source with random steps — partial,
// empty and out-of-order replies, queries left pending or failed, height
// bumps, clock moves and reorgs — over a generated chain whose logs register
// addresses from handlers. Every reply is honest to the chain as it stands, so
// whatever the steps did, the indexer must end up having handled exactly the
// logs of registered addresses, and must reach the head once every query is
// answered in full.

let makeRandom: int => unit => float = %raw(`seed => {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}`)

let maxReorgDepth = 30
let worldEnd = 150
let randomSteps = 150

let addressOf = (prefix, n) => `0x${prefix}${n->Int.toString->String.padStart(38, "0")}`
let staticAddress = addressOf("aa", 0)
let dynamicAddresses = Array.fromInitializer(~length=8, n => addressOf("d0", n))
// Never registered, so no query may name them and no log of theirs is handled.
let strayAddresses = Array.fromInitializer(~length=2, n => addressOf("e0", n))
let loggingAddresses = [staticAddress]->Array.concat(dynamicAddresses)->Array.concat(strayAddresses)

let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-fuzz
rollback_on_reorg: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: ${maxReorgDepth->Int.toString}
    contracts:
      - name: Gravatar
        address: "${staticAddress}"
        events:
          - event: "TestEvent(address[] addresses)"
`,
  ~schema=`
type Handled {
  id: ID!
  address: String!
  times: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.contractRegister({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  for (const address of event.params.addresses) {
    context.chain.Gravatar.add(address);
  }
});

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  const id = \`\${event.block.number}-\${event.logIndex}\`;
  const existing = await context.Handled.get(id);
  context.Handled.set({ id, address: event.srcAddress.toLowerCase(), times: (existing?.times ?? 0) + 1 });
});
`,
)

type handled = {id: string, address: string, times: int}

type log = {
  blockNumber: int,
  mutable logIndex: int,
  address: string,
  registers: array<string>,
}

type world = {
  mutable logs: array<log>,
  registrationBlocks: dict<int>,
}

let randomInt = (rng, ~min, ~max) =>
  min + (rng() *. (max - min + 1)->Int.toFloat)->Float.toInt->Math.Int.min(max - min)

let pick = (rng, values) =>
  values->Array.getUnsafe(randomInt(rng, ~min=0, ~max=values->Array.length - 1))

let isHandled = (world, log) =>
  log.address === staticAddress ||
    switch world.registrationBlocks->Dict.get(log.address) {
    | Some(registrationBlock) => registrationBlock < log.blockNumber
    | None => false
    }

let logId = log => `${log.blockNumber->Int.toString}-${log.logIndex->Int.toString}`

// Keeps the chain up to `keepUpTo` and draws everything above it afresh: the
// dynamic addresses not yet registered get registered there, each by a log
// from an address already registered before it, so every registration is one
// the indexer should act on.
let regenerateAbove = (world, ~rng, ~keepUpTo) => {
  world.registrationBlocks
  ->Dict.keysToArray
  ->Array.forEach(address =>
    if world.registrationBlocks->Dict.getUnsafe(address) > keepUpTo {
      world.registrationBlocks->Dict.delete(address)
    }
  )
  let drawn = []
  let lastRegistrable = worldEnd - 10
  if keepUpTo < lastRegistrable {
    let planned =
      dynamicAddresses
      ->Array.filter(address => world.registrationBlocks->Dict.get(address)->Option.isNone)
      ->Array.map(address => (randomInt(rng, ~min=keepUpTo + 1, ~max=lastRegistrable), address))
      ->Array.toSorted(((a, _), (b, _)) => Int.compare(a, b))
    let previous = ref(None)
    planned->Array.forEach(((blockNumber, address)) =>
      switch previous.contents {
      | Some(registering) if rng() < 0.3 =>
        registering.registers->Array.push(address)
        world.registrationBlocks->Dict.set(address, registering.blockNumber)
      | _ =>
        let emitters = [staticAddress]->Array.concat(
          dynamicAddresses->Array.filter(emitter =>
            world.registrationBlocks
            ->Dict.get(emitter)
            ->Option.mapOr(false, registeredAt => registeredAt < blockNumber)
          ),
        )
        let registering = {
          blockNumber,
          logIndex: 0,
          address: pick(rng, emitters),
          registers: [address],
        }
        drawn->Array.push(registering)
        previous := Some(registering)
        world.registrationBlocks->Dict.set(address, blockNumber)
      }
    )
    // https://github.com/enviodev/hyperindex/issues/1810
    // Registered again from a later block, often by an emitter in another
    // partition, so the later registration can reach the indexer first. The
    // address is indexed from its earliest one either way.
    planned->Array.forEach(((_, address)) => {
      let registeredAt = world.registrationBlocks->Dict.getUnsafe(address)
      if rng() < 0.3 && registeredAt < lastRegistrable {
        let blockNumber = randomInt(rng, ~min=registeredAt + 1, ~max=lastRegistrable)
        let emitters = [staticAddress]->Array.concat(
          dynamicAddresses->Array.filter(emitter =>
            world.registrationBlocks
            ->Dict.get(emitter)
            ->Option.mapOr(false, emitterRegisteredAt => emitterRegisteredAt < blockNumber)
          ),
        )
        drawn->Array.push({
          blockNumber,
          logIndex: 0,
          address: pick(rng, emitters),
          registers: [address],
        })
      }
    })
  }
  for blockNumber in keepUpTo + 1 to worldEnd {
    if rng() < 0.3 {
      for _ in 1 to rng() < 0.3 ? 2 : 1 {
        let address = pick(rng, loggingAddresses)
        // A log in the block that registers its address would hinge on the
        // order within the block, which FetchStateEarliestItem_test pins.
        let address =
          world.registrationBlocks->Dict.get(address) === Some(blockNumber)
            ? staticAddress
            : address
        drawn->Array.push({blockNumber, logIndex: 0, address, registers: []})
      }
    }
  }
  let shuffled =
    drawn
    ->Array.map(log => (rng(), log))
    ->Array.toSorted(((a, _), (b, _)) => Float.compare(a, b))
    ->Array.map(((_, log)) => log)
  let nextLogIndex = Dict.make()
  shuffled
  ->Array.toSorted((a, b) => Int.compare(a.blockNumber, b.blockNumber))
  ->Array.forEach(log => {
    let key = log.blockNumber->Int.toString
    let logIndex = nextLogIndex->Dict.get(key)->Option.getOr(0)
    log.logIndex = logIndex
    nextLogIndex->Dict.set(key, logIndex + 1)
  })
  world.logs =
    world.logs
    ->Array.filter(log => log.blockNumber <= keepUpTo)
    ->Array.concat(shuffled)
    ->Array.toSorted((a, b) =>
      a.blockNumber === b.blockNumber
        ? Int.compare(a.logIndex, b.logIndex)
        : Int.compare(a.blockNumber, b.blockNumber)
    )
}

let expectedHandled = world =>
  world.logs
  ->Array.filter(log => world->isHandled(log))
  ->Array.map(log => {id: log->logId, address: log.address, times: 1})
  ->Array.toSorted((a, b) => String.compare(a.id, b.id))

// A failed query is retried within the same request until a rollback makes it
// stale; a retry already sent by then is stale too, and none is sent after.
type awaitedRetry = {
  partitionId: string,
  fromBlock: int,
  suggestedToBlock: option<int>,
}

let isRetryOf = (query: MockSource.pendingItemsQuery, retry) =>
  retry.partitionId === query.partitionId &&
  retry.fromBlock === query.fromBlock &&
  switch retry.suggestedToBlock {
  | Some(toBlock) => query.toBlock === Bounded(toBlock) && query.retryCount === 0
  | None => query.retryCount > 0
  }

type fuzz = {
  rng: unit => float,
  world: world,
  source: MockSource.t,
  indexer: IndexerRunner.t,
  mutable height: int,
  violations: array<string>,
  steps: array<string>,
  seen: Set.t<MockSource.pendingItemsQuery>,
  // In flight when a rollback started: the indexer drops their replies.
  stale: Set.t<MockSource.pendingItemsQuery>,
  awaitedRetries: array<awaitedRetry>,
  fetchedByPartition: dict<array<(int, int)>>,
  // Registered by a handled log some reply carried, so a query may name them.
  servedRegistrations: Set.t<string>,
  // Blocks a reply told the indexer the hash of, so a reorg can contradict one.
  observedBlocks: Set.t<int>,
  // What lookups during a rollback report as still on the canonical chain.
  mutable validUpTo: int,
  mutable reorgsSeen: int,
  mutable reorgsInjected: int,
  mutable injectedValidUpTo: option<int>,
}

let note = (fuzz, step) => {
  fuzz.steps->Array.push(step)
  if fuzz.steps->Array.length > 40 {
    fuzz.steps->Array.shift->ignore
  }
}

let describeQuery = (query: MockSource.pendingItemsQuery) =>
  `p${query.partitionId} ${query.fromBlock->Int.toString}..${switch query.toBlock {
    | Bounded(toBlock) => toBlock->Int.toString
    | Unbounded => ""
    }}`

let violate = (fuzz, message) =>
  fuzz.violations->Array.push(`${message} (after: ${fuzz.steps->Array.join(" | ")})`)

let inspectNewQueries = fuzz =>
  fuzz.source.pendingItemsQueries->Array.forEach(query =>
    if !(fuzz.seen->Set.has(query)) {
      fuzz.seen->Set.add(query)
      let described = query->describeQuery
      let retryOf = fuzz.awaitedRetries->Array.findIndex(retry => query->isRetryOf(retry))
      if retryOf !== -1 {
        fuzz.awaitedRetries->Array.splice(~start=retryOf, ~remove=1, ~insert=[])
      }
      if query.fromBlock < 1 || query.fromBlock > fuzz.height {
        fuzz->violate(`${described} starts outside 1..${fuzz.height->Int.toString}`)
      }
      switch query.toBlock {
      | Bounded(toBlock) if toBlock < query.fromBlock || toBlock > fuzz.height =>
        fuzz->violate(`${described} ends outside its start..${fuzz.height->Int.toString}`)
      | _ => ()
      }

      // Gravatar is fetched by address, so a query naming none must tell the
      // source to gate it on the address store; else it reads as wildcard.
      if (
        query->MockSource.addresses->Array.length === 0 &&
          !(
            (query->MockSource.selection).clientFilteredContracts
            ->Option.getOr([])
            ->Array.includes("Gravatar")
          )
      ) {
        fuzz->violate(`${described} names no address and doesn't client-filter Gravatar`)
      }

      // A stale query was planned on the orphaned chain, so it answers only
      // to the bounds every query keeps.
      if !(fuzz.stale->Set.has(query)) {
        query
        ->MockSource.addresses
        ->Array.map(address => address->Address.toString->String.toLowerCase)
        ->Array.forEach(address =>
          if address !== staticAddress && !(fuzz.servedRegistrations->Set.has(address)) {
            fuzz->violate(`${described} names ${address}, which no handled log registered`)
          }
        )
        fuzz.fetchedByPartition
        ->Dict.get(query.partitionId)
        ->Option.getOr([])
        ->Array.forEach(((fetchedFrom, fetchedTo)) =>
          if (
            fetchedTo >= query.fromBlock &&
              switch query.toBlock {
              | Bounded(toBlock) => fetchedFrom <= toBlock
              | Unbounded => true
              }
          ) {
            fuzz->violate(
              `${described} re-fetches ${fetchedFrom->Int.toString}..${fetchedTo->Int.toString}, which its partition already fetched`,
            )
          }
        )
      }
    }
  )

let upperBound = (fuzz, query: MockSource.pendingItemsQuery) =>
  switch query.toBlock {
  | Bounded(toBlock) => Math.Int.min(toBlock, fuzz.height)
  | Unbounded => fuzz.height
  }

let passesAddressStoreGate = (fuzz, log) =>
  log.address === staticAddress ||
    (fuzz.servedRegistrations->Set.has(log.address) && fuzz.world->isHandled(log))

let respond = (fuzz, query: MockSource.pendingItemsQuery, ~latest, ~prevRangeLastBlock=?) => {
  let addresses =
    query->MockSource.addresses->Array.map(address => address->Address.toString->String.toLowerCase)
  let served = fuzz.world.logs->Array.filter(log =>
    log.blockNumber >= query.fromBlock &&
    log.blockNumber <= latest &&
    (// A client-filtered query names no address. Either way the source's
    // client gates each log on the indexer's address store, dropping one
    // emitted before its address was registered.
    addresses->Array.length === 0 || addresses->Array.includes(log.address)) &&
    fuzz->passesAddressStoreGate(log)
  )
  (query->MockSource.control).respond({
    items: served->Array.map((log): MockSource.itemMock => {
      event: "Gravatar.TestEvent",
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
      srcAddress: log.address,
      params: dict{"addresses": log.registers->(Utils.magic: array<string> => unknown)},
    }),
    latestFetchedBlockNumber: latest,
    knownHeight: fuzz.height,
    ?prevRangeLastBlock,
  })
  if !(fuzz.stale->Set.has(query)) && prevRangeLastBlock->Option.isNone {
    served->Array.forEach(log => {
      if fuzz.world->isHandled(log) {
        log.registers->Array.forEach(address => fuzz.servedRegistrations->Set.add(address))
      }
      fuzz.observedBlocks->Set.add(log.blockNumber)
    })
    fuzz.observedBlocks->Set.add(latest)
    fuzz.observedBlocks->Set.add(query.fromBlock - 1)
    let fetched = switch fuzz.fetchedByPartition->Dict.get(query.partitionId) {
    | Some(fetched) => fetched
    | None =>
      let fetched = []
      fuzz.fetchedByPartition->Dict.set(query.partitionId, fetched)
      fetched
    }
    fetched->Array.push((query.fromBlock, latest))
  }
}

let answerBlockHashLookups = fuzz =>
  if fuzz.source.getBlockHashesCalls->Array.length > 0 {
    fuzz.source.resolveGetBlockHashes(
      fuzz.source.getBlockHashesCalls
      ->Array.flat
      ->Array.map((blockNumber): BufferPage.observedBlock => {
        blockNumber,
        blockHash: blockNumber <= fuzz.validUpTo
          ? `0x${blockNumber->Int.toString}`
          : `0x${blockNumber->Int.toString}a`,
        blockTimestamp: blockNumber,
      }),
    )
    fuzz.source.getBlockHashesCalls->Utils.Array.clearInPlace
  }

let logsWithMessage = (fuzz, matches) =>
  fuzz.indexer.allLogsAsJson()->Array.filter(line =>
    switch line->Dict.get("msg") {
    | Some(String(msg)) => matches(msg)
    | _ => false
    }
  )

let reorgsDetected = fuzz =>
  fuzz
  ->logsWithMessage(msg => msg->String.startsWith("Blockchain reorg detected"))
  ->Array.length

let lastRollbackTarget = fuzz =>
  switch fuzz->logsWithMessage(msg => msg === "Started rollback on reorg")->Array.at(-1) {
  | Some(line) =>
    switch line->Dict.get("targetBlockNumber") {
    | Some(Number(target)) => Some(target->Float.toInt)
    | _ => None
    }
  | None => None
  }

let failStalled = (fuzz, ~seed, message) =>
  JsError.throwWithMessage(
    `${message} (seed ${seed->Int.toString}, height ${fuzz.height->Int.toString})\nsteps: ${fuzz.steps->Array.join(
        " | ",
      )}`,
  )

let completeRollback = async (fuzz, ~seed) => {
  let ready = ref(false)
  fuzz.indexer.getRollbackReadyPromise()->Promise.thenResolve(() => ready := true)->ignore
  let rounds = ref(0)
  while !ready.contents && rounds.contents < 2000 {
    rounds := rounds.contents + 1

    // No query goes out while the rollback is under way, so any pending now
    // was asked of the orphaned chain.
    if fuzz.indexer.isResolvingReorg() {
      fuzz.source.pendingItemsQueries->Array.forEach(query => fuzz.stale->Set.add(query))
    }
    fuzz->answerBlockHashLookups
    // Real time: the rollback reads and writes the database between lookups.
    await Utils.delay(1)
  }
  if !ready.contents {
    fuzz->failStalled(~seed, "a rollback never finished")
  }
  // Queries first seen before this step were asked of the orphaned chain. The
  // ones the step brought are taken for the rollback's re-fetches.
  fuzz.source.pendingItemsQueries->Array.forEach(query =>
    if fuzz.seen->Set.has(query) {
      fuzz.stale->Set.add(query)
    }
  )
  fuzz.source.pendingItemsQueries->Array.forEach(query =>
    if fuzz.awaitedRetries->Array.some(retry => query->isRetryOf(retry)) {
      fuzz.stale->Set.add(query)
    }
  )
  fuzz.awaitedRetries->Utils.Array.clearInPlace
  let target = fuzz->lastRollbackTarget->Option.getOr(0)
  switch fuzz.injectedValidUpTo {
  | Some(validUpTo) =>
    if target > validUpTo {
      fuzz->violate(
        `rolled back to ${target->Int.toString}, above ${validUpTo->Int.toString}, the last block the source still had`,
      )
    }
    fuzz.world->regenerateAbove(~rng=fuzz.rng, ~keepUpTo=validUpTo)
    fuzz.injectedValidUpTo = None
  | None => ()
  }
  fuzz->note(`rolled back to ${target->Int.toString}`)
  fuzz.fetchedByPartition
  ->Dict.keysToArray
  ->Array.forEach(key => fuzz.fetchedByPartition->Dict.delete(key))
  fuzz.servedRegistrations
  ->Set.toArray
  ->Array.forEach(address =>
    switch fuzz.world.registrationBlocks->Dict.get(address) {
    | Some(registeredAt) if registeredAt <= target => ()
    | _ => fuzz.servedRegistrations->Set.delete(address)->ignore
    }
  )
  fuzz.observedBlocks
  ->Set.toArray
  ->Array.forEach(blockNumber =>
    if blockNumber > target {
      fuzz.observedBlocks->Set.delete(blockNumber)->ignore
    }
  )
}

let settle = async (fuzz, ~seed) => {
  await fuzz.indexer.advanceTime(0)
  fuzz->answerBlockHashLookups
  let detected = fuzz->reorgsDetected
  if detected > fuzz.reorgsSeen {
    fuzz.reorgsSeen = detected
    await fuzz->completeRollback(~seed)
  }
  fuzz->inspectNewQueries
}

let liveQueries = fuzz =>
  fuzz.source.pendingItemsQueries->Array.filter(query => !(fuzz.stale->Set.has(query)))

let pickQuery = fuzz =>
  switch fuzz.source.pendingItemsQueries {
  | [] => None
  | queries => Some(pick(fuzz.rng, queries))
  }

let respondRandomly = fuzz =>
  switch fuzz->pickQuery {
  | Some(query) if fuzz->upperBound(query) >= query.fromBlock =>
    let upper = fuzz->upperBound(query)
    let latest = fuzz.rng() < 0.4 ? upper : randomInt(fuzz.rng, ~min=query.fromBlock, ~max=upper)
    fuzz->note(`reply ${query->describeQuery} up to ${latest->Int.toString}`)
    fuzz->respond(query, ~latest)
  | _ => ()
  }

let failRandomly = fuzz =>
  switch fuzz->pickQuery {
  | Some(query) =>
    let upper = fuzz->upperBound(query)
    let suggestedToBlock =
      fuzz.rng() < 0.5 && upper > query.fromBlock
        ? Some(randomInt(fuzz.rng, ~min=query.fromBlock, ~max=upper - 1))
        : None
    let failure: Source.failure = switch suggestedToBlock {
    | Some(toBlock) => NarrowRange({toBlock, attemptedToBlock: upper})
    | None => Backoff({message: "fuzz", backoffMillis: randomInt(fuzz.rng, ~min=0, ~max=300)})
    }
    if !(fuzz.stale->Set.has(query)) {
      fuzz.awaitedRetries->Array.push({
        partitionId: query.partitionId,
        fromBlock: query.fromBlock,
        suggestedToBlock,
      })
    }
    fuzz->note(`fail ${query->describeQuery}`)
    (query->MockSource.control).fail(failure, ~requestStats=[])
  | None => ()
  }

// Replies with a hash for an already reported block that contradicts it, as a
// source on a new fork would. Once the indexer acts on it, the chain above the
// block the lookups still confirm is drawn afresh.
let injectReorg = async (fuzz, ~seed) => {
  let lowest = fuzz.height - maxReorgDepth + 1
  let candidates =
    fuzz
    ->liveQueries
    ->Array.filterMap(query => {
      let blocks =
        fuzz.observedBlocks
        ->Set.toArray
        ->Array.filter(blockNumber =>
          blockNumber > Math.Int.max(lowest, 1) && blockNumber < query.fromBlock
        )
      blocks->Array.length > 0 && fuzz->upperBound(query) >= query.fromBlock
        ? Some((query, blocks))
        : None
    })
  switch candidates {
  | [] => fuzz->respondRandomly
  | candidates =>
    let (query, blocks) = pick(fuzz.rng, candidates)
    let reorged = pick(fuzz.rng, blocks)
    let validUpTo = randomInt(
      fuzz.rng,
      ~min=Math.Int.max(Math.Int.max(lowest, 1), reorged - 10),
      ~max=reorged - 1,
    )
    fuzz->note(
      `reorg at ${reorged->Int.toString} keeping ${validUpTo->Int.toString} via ${query->describeQuery}`,
    )
    fuzz.validUpTo = validUpTo
    fuzz.injectedValidUpTo = Some(validUpTo)
    fuzz.reorgsInjected = fuzz.reorgsInjected + 1
    let before = fuzz->reorgsDetected
    fuzz->respond(
      query,
      ~latest=query.fromBlock,
      ~prevRangeLastBlock={blockNumber: reorged, blockHash: `0x${reorged->Int.toString}a`},
    )
    let rounds = ref(0)
    while fuzz->reorgsDetected === before && rounds.contents < 2000 {
      rounds := rounds.contents + 1
      // Real time: the reply is checked against the block store off the clock.
      await Utils.delay(1)
    }
    if fuzz->reorgsDetected === before {
      fuzz.injectedValidUpTo = None
      fuzz->note("reorg went unnoticed")
    }
    await fuzz->settle(~seed)
  }
}

let bumpHeight = fuzz =>
  if fuzz.height < worldEnd {
    fuzz.height = Math.Int.min(worldEnd, fuzz.height + randomInt(fuzz.rng, ~min=1, ~max=12))
    fuzz->note(`height ${fuzz.height->Int.toString}`)
    fuzz.source.setAutoHeight(fuzz.height)
  }

let runRandomStep = async (fuzz, ~seed) => {
  let roll = fuzz.rng()
  if roll < 0.4 {
    fuzz->respondRandomly
  } else if roll < 0.47 {
    fuzz->failRandomly
  } else if roll < 0.62 {
    fuzz->bumpHeight
  } else if roll < 0.77 {
    let millis = randomInt(fuzz.rng, ~min=0, ~max=1500)
    fuzz->note(`advance ${millis->Int.toString}ms`)
    await fuzz.indexer.advanceTime(millis)
  } else if roll < 0.82 {
    await fuzz->injectReorg(~seed)
  } else {
    fuzz->note("leave pending")
  }
  await fuzz->settle(~seed)
}

let reachedTheHead = async fuzz =>
  fuzz.source.pendingItemsQueries->Array.length === 0 &&
    switch await fuzz.indexer.queryChains() {
    | [chain] => chain.progressBlock >= worldEnd
    | _ => false
    }

let drainHonestly = async (fuzz, ~seed) => {
  fuzz.height = worldEnd
  fuzz->note(`height ${worldEnd->Int.toString}, answering everything`)
  fuzz.source.setAutoHeight(worldEnd)
  let rounds = ref(0)
  let reached = ref(false)
  while !reached.contents && rounds.contents < 200 {
    rounds := rounds.contents + 1
    fuzz.source.pendingItemsQueries
    ->Array.copy
    ->Array.forEach(query => fuzz->respond(query, ~latest=fuzz->upperBound(query)))
    await fuzz.indexer.advanceTime(1000)
    await fuzz->settle(~seed)
    reached := (await fuzz->reachedTheHead)
  }
  if !reached.contents {
    fuzz->failStalled(
      ~seed,
      `never reached block ${worldEnd->Int.toString} with every query answered`,
    )
  }
}

let fuzzSeed = async (~t: Vitest.testContext, ~indexer, ~source: MockSource.t, ~seed) => {
  let rng = makeRandom(seed)
  let world = {logs: [], registrationBlocks: Dict.make()}
  world->regenerateAbove(~rng, ~keepUpTo=0)
  let fuzz = {
    rng,
    world,
    source,
    indexer,
    height: randomInt(rng, ~min=40, ~max=80),
    violations: [],
    steps: [],
    seen: Set.make(),
    awaitedRetries: [],
    stale: Set.make(),
    fetchedByPartition: Dict.make(),
    servedRegistrations: Set.make(),
    observedBlocks: Set.make(),
    validUpTo: worldEnd,
    reorgsSeen: 0,
    reorgsInjected: 0,
    injectedValidUpTo: None,
  }
  source.setAutoHeight(fuzz.height)
  await fuzz->settle(~seed)
  for _ in 1 to randomSteps {
    await fuzz->runRandomStep(~seed)
  }
  await fuzz->drainHonestly(~seed)
  await indexer.waitUntilIdle()

  // A conflict against a hash the store doesn't hold goes unnoticed, so not
  // every injection rolls back; none rolling back means reorg detection is gone.
  if fuzz.reorgsInjected > 0 && fuzz.reorgsSeen === 0 {
    fuzz->violate(
      `none of the ${fuzz.reorgsInjected->Int.toString} conflicting hashes injected triggered a rollback`,
    )
  }
  let handled =
    (await indexer.query("Handled"): array<handled>)->Array.toSorted((a, b) =>
      String.compare(a.id, b.id)
    )
  t.expect(
    (handled, fuzz.violations),
    ~message=`seed ${seed->Int.toString}: every log of a registered address handled once, every query well-formed`,
  ).toEqual((world->expectedHandled, []))
}

describe("Fetching through random replies, registrations, height changes and reorgs", () => {
  // Seeds 106 and 121 deliver an address's later registration before its
  // earlier one. https://github.com/enviodev/hyperindex/issues/1810
  [(1, 1, 3), (2, 2, 5), (3, 3, 1000), (4, 1, 5), (106, 1, 3), (121, 1, 1000)]->Array.forEach(((
    seed,
    maxAddrInPartition,
    clientFilterAddressThreshold,
  )) =>
    scenario->Scenario.it(
      `handles every registered address's logs once and reaches the head (seed ${seed->Int.toString})`,
      ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
      ~maxAddrInPartition,
      ~clientFilterAddressThreshold,
      async (~t, ~indexer, ~source) => await fuzzSeed(~t, ~indexer, ~source=source(1337), ~seed),
    )
  )
})
