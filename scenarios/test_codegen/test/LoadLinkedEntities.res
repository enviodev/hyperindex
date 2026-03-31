open Vitest

/// NOTE: diagrams for these tests can be found here: https://www.figma.com/file/TrBPqQHYoJ8wg6e0kAynZo/Scenarios-to-test-Linked-Entities?type=whiteboard&node-id=0%3A1&t=CZAE4T4oY9PCbszw-1

describe_skip("Linked Entity Loader Integration Test", () => {
  ()
})

describe("Async linked entity loaders", () => {
  Async.it("should update the big int to be the same ", async t => {
    // Initializing values
    let messageFromC = "Hi there I was in C originally"
    let c: Indexer.Entities.C.t = {
      id: "hasStringToCopy",
      stringThatIsMirroredToA: messageFromC,
      a_id: "",
    }
    let b: Indexer.Entities.B.t = {
      id: "hasC",
      c_id: Some(c.id),
    }
    let a: Indexer.Entities.A.t = {
      id: EventHandlers.aIdWithGrandChildC,
      b_id: b.id,
      optionalStringToTestLinkedEntities: None,
    }
    let bNoC: Indexer.Entities.B.t = {
      id: "noC",
      c_id: None,
    }
    let aNoGrandchild: Indexer.Entities.A.t = {
      id: EventHandlers.aIdWithNoGrandChildC,
      b_id: bNoC.id,
      optionalStringToTestLinkedEntities: None,
    }

    let indexer = Indexer.createTestIndexer()
    let aOps = indexer->Indexer.getTestIndexerEntityOperations(Indexer.Entities.A)
    let bOps = indexer->Indexer.getTestIndexerEntityOperations(Indexer.Entities.B)
    let cOps = indexer->Indexer.getTestIndexerEntityOperations(Indexer.Entities.C)

    aOps.set(a)
    aOps.set(aNoGrandchild)
    bOps.set(b)
    bOps.set(bNoC)
    cOps.set(c)

    let _ = await indexer.process({
      chains: {
        \"1337": {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            Indexer.makeSimulateItem(
              OnEvent({
                event: Gravatar(TestEventThatCopiesBigIntViaLinkedEntities),
                params: {
                  param_that_should_be_removed_when_issue_1026_is_fixed: "",
                },
              }),
            ),
          ],
        },
      },
    })

    // Expected string copied from C
    let updatedA = await aOps.get(EventHandlers.aIdWithGrandChildC)
    let stringInAFromC = updatedA->Belt.Option.flatMap(a => a.optionalStringToTestLinkedEntities)
    t.expect(stringInAFromC).toEqual(Some(messageFromC))

    // Expected string to be null still since no c grandchild.
    let updatedANoGrandchild = await aOps.get(EventHandlers.aIdWithNoGrandChildC)
    let optionalStringToTestLinkedEntitiesNoGrandchild =
      updatedANoGrandchild->Belt.Option.flatMap(a => a.optionalStringToTestLinkedEntities)

    t.expect(optionalStringToTestLinkedEntitiesNoGrandchild).toEqual(None)
  })
})
