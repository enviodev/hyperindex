type stub<'a> = 'a
@module("sinon") external stub: unit => stub<'a> = "stub"

let callStub0 = (callback_stub: stub<unit => 'a>) => callback_stub()
let callStub1 = (callback_stub: stub<'a => 'b>, arg1: 'a) => callback_stub(arg1)

@send external resetStub: stub<'a> => unit = "reset"

type call
@send external getCall: (stub<'a>, int) => call = "getCall"
@send external getCalls: stub<'a> => array<call> = "getCalls"

@get external getCallArgs: call => array<'a> = "args"
@get external getCallFirstArg: call => 'a = "firstArg"
