open Jest
open Expect
describe("E2E Mock Event Batch", () => {
  beforeAllPromise(async () => {
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity1)
    DbStub.setGravatarDb(~gravatar=MockEntities.gravatarEntity2)
    await Index.processEventBatch(MockEvents.eventBatch)
  })

  afterAll(() => {
    ContextStub.insertMock->MockJs.mockClear
    ContextStub.updateMock->MockJs.mockClear
  })

  test("3 newGravitar event insert calls in order", () => {
    let insertCalls = ContextStub.insertMock->MockJs.calls
    expect(insertCalls)->toEqual([
      MockEvents.newGravatar1.id,
      MockEvents.newGravatar2.id,
      MockEvents.newGravatar3.id,
    ])
  })

  test("3 updateGravitar event insert calls in order", () => {
    let insertCalls = ContextStub.insertMock->MockJs.calls
    expect(insertCalls)->toEqual([
      MockEvents.updateGravatar1.id,
      MockEvents.updateGravatar2.id,
      MockEvents.updateGravatar3.id,
    ])
  })
})
