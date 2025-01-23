type t<'a> = {
  mutable data: 'a,
  mutable isImmutable: bool,
  copy: 'a => 'a,
}

let make = (data: 'a, ~copy): t<'a> => {data, isImmutable: true, copy}
let getDataRef = (self: t<'a>): 'a => self.data
let getData = (self: t<'a>): 'a =>
  if self.isImmutable {
    self.data
  } else {
    self.data->self.copy
  }

let copy = ({isImmutable, data, copy}: t<'a>): t<'a> =>
  if isImmutable {
    data->make(~copy)
  } else {
    data->copy->make(~copy)
  }

let mutate = (self: t<'a>, fn) =>
  if self.isImmutable {
    self.isImmutable = false
    self.data = self.data->self.copy
    fn(self.data)
  } else {
    fn(self.data)
  }

module Array = {
  type t<'a> = t<array<'a>>
  module InternalFunctions = {
    let copy = arr => arr->Array.copy
    let push = (arr, item) => arr->Js.Array2.push(item)->ignore
    let pop = arr => arr->Js.Array2.pop
  }
  let make = (data: array<'a>): t<'a> => make(data, ~copy=InternalFunctions.copy)
  let push = (self: t<'a>, item) => self->mutate(arr => arr->InternalFunctions.push(item))
  let pop = (self: t<'a>) => self->mutate(InternalFunctions.pop)
  let length = (self: t<'a>) => self->getDataRef->Array.length
  let last = (self: t<'a>) => self->getDataRef->Utils.Array.last
}
