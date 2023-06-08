@val external jsArrayCreate: int => array<'a> = "Array"

/* Given a comaprator and two sorted lists, combine them into a single sorted list */
let mergeSorted = (f: 'a => 'b, xs: array<'a>, ys: array<'a>) => {
  if Array.length(xs) == 0 {
    ys
  } else if Array.length(ys) == 0 {
    xs
  } else {
    let n = Array.length(xs) + Array.length(ys)
    let result = jsArrayCreate(n)

    let rec loop = (i, j, k) => {
      if i < Array.length(xs) && j < Array.length(ys) {
        if f(xs[i]) <= f(ys[j]) {
          result[k] = xs[i]
          loop(i + 1, j, k + 1)
        } else {
          result[k] = ys[j]
          loop(i, j + 1, k + 1)
        }
      } else if i < Array.length(xs) {
        result[k] = xs[i]
        loop(i + 1, j, k + 1)
      } else if j < Array.length(ys) {
        result[k] = ys[j]
        loop(i, j + 1, k + 1)
      }
    }

    loop(0, 0, 0)
    result
  }
}

// A good friend when you're pretty confused.
//
// let inspectObj = _myObject =>
//   %raw(`require('util').inspect(_myObject, {showHidden: false, depth: null, colors: true})`)
