// A scalable bloom filter over string keys: a stack of layers, each sized for a
// capacity at about 1% false positives, with a 4x larger one pushed when the
// newest fills up. A key that was added is always reported; one never added is
// reported with a probability of roughly 1% per layer.

@get_index external getWord: (Uint32Array.t, int) => int = ""
@set_index external setWord: (Uint32Array.t, int, int) => unit = ""

type layer = {
  bits: Uint32Array.t,
  // Bit count minus one; the bit count is a power of two.
  mask: int,
  capacity: int,
  mutable count: int,
}

type t = {mutable layers: array<layer>, mutable count: int}

let hashCount = 7
let bitsPerKey = 10
let growth = 4

let rec nextPowerOfTwo = (n, acc) => acc >= n ? acc : nextPowerOfTwo(n, acc * 2)

let makeLayer = (~capacity) => {
  // At least one word, so a tiny capacity still has a mask to index with.
  let bitCount = nextPowerOfTwo(capacity * bitsPerKey, 32)
  {
    bits: Uint32Array.fromLength(bitCount / 32),
    mask: bitCount - 1,
    capacity,
    count: 0,
  }
}

let make = (~initialCapacity=65_536) => {layers: [makeLayer(~capacity=initialCapacity)], count: 0}

// cyrb53's two 32-bit lanes, combined Kirsch–Mitzenmacher style into the
// layer's probe positions. Constants above 2^31 are written as their signed
// 32-bit equivalents.
let hash1 = ref(0)
let hash2 = ref(0)
let hashKey = (key: string) => {
  let h1 = ref(-559038737)
  let h2 = ref(1103547991)
  for i in 0 to key->String.length - 1 {
    let ch = key->String.charCodeAtUnsafe(i)
    h1 := Math.Int.imul(h1.contents->Int.bitwiseXor(ch), -1640531535)
    h2 := Math.Int.imul(h2.contents->Int.bitwiseXor(ch), 1597334677)
  }
  let a = h1.contents
  let b = h2.contents
  let a = Math.Int.imul(a->Int.bitwiseXor(a->Int.shiftRightUnsigned(16)), -2048144789)
  let a =
    a->Int.bitwiseXor(Math.Int.imul(b->Int.bitwiseXor(b->Int.shiftRightUnsigned(13)), -1028477387))
  let b = Math.Int.imul(b->Int.bitwiseXor(b->Int.shiftRightUnsigned(16)), -2048144789)
  let b =
    b->Int.bitwiseXor(Math.Int.imul(a->Int.bitwiseXor(a->Int.shiftRightUnsigned(13)), -1028477387))
  hash1 := a
  // Odd, so the probes step through every position of a power-of-two layer.
  hash2 := b->Int.bitwiseOr(1)
}

let layerHas = (layer: layer) => {
  let found = ref(true)
  let i = ref(0)
  while found.contents && i.contents < hashCount {
    let bit =
      (hash1.contents + Math.Int.imul(i.contents, hash2.contents))->Int.bitwiseAnd(layer.mask)
    let word = layer.bits->getWord(bit->Int.shiftRightUnsigned(5))
    if word->Int.bitwiseAnd(1->Int.shiftLeft(bit->Int.bitwiseAnd(31))) === 0 {
      found := false
    }
    i := i.contents + 1
  }
  found.contents
}

let layerAdd = (layer: layer) => {
  for i in 0 to hashCount - 1 {
    let bit = (hash1.contents + Math.Int.imul(i, hash2.contents))->Int.bitwiseAnd(layer.mask)
    let index = bit->Int.shiftRightUnsigned(5)
    layer.bits->setWord(
      index,
      layer.bits->getWord(index)->Int.bitwiseOr(1->Int.shiftLeft(bit->Int.bitwiseAnd(31))),
    )
  }
  layer.count = layer.count + 1
}

let hashedHas = (self: t) => {
  let found = ref(false)
  let i = ref(0)
  while !found.contents && i.contents < self.layers->Array.length {
    if self.layers->Array.getUnsafe(i.contents)->layerHas {
      found := true
    }
    i := i.contents + 1
  }
  found.contents
}

let mightContain = (self: t, key: string) => {
  hashKey(key)
  self->hashedHas
}

let add = (self: t, key: string) => {
  hashKey(key)

  // Already reported present: setting its bits again would only spend
  // capacity, filling the layer faster than distinct keys do.
  if !(self->hashedHas) {
    let last = self.layers->Array.getUnsafe(self.layers->Array.length - 1)
    let layer = if last.count >= last.capacity {
      let next = makeLayer(~capacity=last.capacity * growth)
      self.layers->Array.push(next)->ignore
      next
    } else {
      last
    }
    layer->layerAdd
    self.count = self.count + 1
  }
}

// A layer storage built from `count` keys. Kept ahead of the layer `add` fills,
// which keeps taking the keys set since.
let addBuiltLayer = (self: t, ~bits: Uint32Array.t, ~count) => {
  let bitCount = bits->TypedArray.length * 32
  self.layers =
    [{bits, mask: bitCount - 1, capacity: bitCount / bitsPerKey, count}]->Array.concat(self.layers)
  self.count = self.count + count
}

let byteSize = (self: t) =>
  self.layers->Array.reduce(0, (acc, layer) => acc + layer.bits->TypedArray.byteLength)
