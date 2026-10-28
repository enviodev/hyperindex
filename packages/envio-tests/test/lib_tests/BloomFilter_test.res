open Vitest

let address = n => "0x" ++ n->Int.toString(~radix=16)->String.padStart(40, "0")

describe("BloomFilter", () => {
  it("Reports every added key and few others, across grown layers", t => {
    let filter = BloomFilter.make(~initialCapacity=1_000)
    let added = 50_000
    for i in 0 to added - 1 {
      filter->BloomFilter.add(address(i))
    }
    let missing = ref(0)
    for i in 0 to added - 1 {
      if !(filter->BloomFilter.mightContain(address(i))) {
        missing := missing.contents + 1
      }
    }
    let falsePositives = ref(0)
    let probes = 100_000
    for i in 0 to probes - 1 {
      if filter->BloomFilter.mightContain(address(added + i)) {
        falsePositives := falsePositives.contents + 1
      }
    }
    t.expect({
      "missing": missing.contents,
      "layers": filter.layers->Array.length,
      "falsePositivesUnder4Percent": falsePositives.contents * 25 < probes,
    }).toEqual({
      "missing": 0,
      "layers": 4,
      "falsePositivesUnder4Percent": true,
    })
  })
})
