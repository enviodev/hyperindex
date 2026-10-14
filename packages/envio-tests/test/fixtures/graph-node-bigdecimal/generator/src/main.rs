//! Prints BigDecimal vectors computed the way graph-node computes them:
//! `bigdecimal` 0.1.2 plus graph-node's `BigDecimal::normalized`.
//!
//!   cargo run --manifest-path Cargo.toml > ../vectors.json
use old_bigdecimal::BigDecimal as Old;
use std::str::FromStr;

// graph/src/data/store/scalar/bigdecimal.rs `normalized`.
fn normalized(b: Old) -> Old {
    use old_bigdecimal::Zero;
    if b == Old::zero() {
        return Old::zero();
    }
    let rounded = b.with_prec(34);
    let (bigint, exp) = rounded.as_bigint_and_exponent();
    let (sign, mut digits) = bigint.to_radix_be(10);
    let trailing = digits.iter().rev().take_while(|d| **d == 0).count();
    digits.truncate(digits.len() - trailing);
    let int_val = num_bigint::BigInt::from_radix_be(sign, &digits, 10).unwrap();
    Old::new(int_val, exp - trailing as i64)
}

// A value as a mapping holds it. graph-node normalizes a result once in the
// operation (`From<OldBigDecimal>`) and again whenever it crosses from
// AssemblyScript back into the host, to be stored, printed or operated on
// (`FromAscObj` builds it with `BigDecimal::new`). The second pass changes
// a negative the first left at 35 digits.
fn held(b: Old) -> Old {
    normalized(normalized(b))
}

struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn random_decimal(rng: &mut Lcg) -> String {
    let len = 1 + rng.below(45) as usize;
    let mut digits: String = (0..len).map(|_| char::from(b'0' + rng.below(10) as u8)).collect();
    if digits.chars().all(|c| c == '0') {
        digits.replace_range(0..1, "7");
    }
    let point = rng.below(len as u64 + 1) as usize;
    let sign = if rng.below(2) == 0 { "" } else { "-" };
    if point == len {
        format!("{sign}{digits}")
    } else {
        format!("{sign}{}.{}", if point == 0 { "0" } else { &digits[..point] }, &digits[point..])
    }
}

fn main() {
    let mut rng = Lcg(20261007);
    let mut lines = Vec::new();
    for i in 0..400 {
        let a = random_decimal(&mut rng);
        let b = random_decimal(&mut rng);
        let (x, y) = (held(Old::from_str(&a).unwrap()), held(Old::from_str(&b).unwrap()));
        let (op, result) = match i % 5 {
            0 => ("plus", held(x + y)),
            1 => ("minus", held(x - y)),
            2 => ("times", held(x * y)),
            3 => ("div", held(x / y)),
            _ => ("parse", x),
        };
        lines.push(format!("  [\"{op}\", \"{a}\", \"{b}\", \"{result}\"]"));
    }
    for (op, a, b) in shapes(&mut rng) {
        let (x, y) = (held(Old::from_str(&a).unwrap()), held(Old::from_str(&b).unwrap()));
        let result = match op {
            "plus" => held(x + y),
            "minus" => held(x - y),
            "times" => held(x * y),
            "div" => held(x / y),
            _ => x,
        };
        lines.push(format!("  [\"{op}\", \"{a}\", \"{b}\", \"{result}\"]"));
    }
    println!("[\n{}\n]", lines.join(",\n"));
}

fn digits(rng: &mut Lcg, len: usize) -> String {
    let mut s: String = (0..len).map(|_| char::from(b'0' + rng.below(10) as u8)).collect();
    s.replace_range(0..1, &(1 + rng.below(9)).to_string());
    s
}

/// The shapes a fast path could get wrong: powers of ten (Uniswap's
/// `exponentToBigDecimal`), trailing zeros, results at 33–36 digits, negatives
/// whose coefficient sits at a power of two (the crate's digit undercount),
/// carries into a new digit, exact and repeating division, zeros.
fn shapes(rng: &mut Lcg) -> Vec<(&'static str, String, String)> {
    let mut out = Vec::new();
    let pow = |k: usize| format!("1{}", "0".repeat(k));
    for k in 0..40 {
        out.push(("times", pow(k), "10".to_string()));
        out.push(("div", "1".to_string(), pow(k)));
        out.push(("div", pow(k), "7".to_string()));
        out.push(("times", format!("-{}", pow(k)), "10".to_string()));
        out.push(("parse", format!("{}.000", pow(k)), "0".to_string()));
    }
    for (a, b) in [("0.25", "0.75"), ("100", "-0.5"), ("1500", "0"), ("-0", "0"), ("0.000", "5")] {
        for op in ["plus", "minus", "times", "parse"] {
            out.push((op, a.to_string(), b.to_string()));
        }
    }
    for (a, b) in [("6", "3"), ("1", "8"), ("1", "1024"), ("-1", "3"), ("2", "-3"), ("0", "7"), ("7", "7"), ("5", "1")] {
        out.push(("div", a.to_string(), b.to_string()));
    }
    let nines = |n: usize| "9".repeat(n);
    for n in [33, 34, 35, 36] {
        out.push(("plus", nines(n), "0.5".to_string()));
        out.push(("plus", nines(n), "1".to_string()));
        out.push(("plus", format!("-{}", nines(n)), "-1".to_string()));
        out.push(("parse", format!("{}5", nines(n - 1)), "0".to_string()));
        out.push(("parse", format!("-{}5", nines(n - 1)), "0".to_string()));
    }
    for m in [100u32, 110, 111, 112, 113, 120, 150] {
        let two = num_bigint::BigInt::from(1u8) << m as usize;
        for delta in [-1i64, 0, 1] {
            let v = &two + num_bigint::BigInt::from(delta);
            out.push(("parse", format!("-{v}"), "0".to_string()));
            out.push(("times", format!("-{v}"), "1.5".to_string()));
            out.push(("plus", format!("{v}"), "0.1".to_string()));
        }
    }
    for _ in 0..200 {
        let len = 30 + rng.below(8) as usize;
        let a = digits(rng, len);
        let len_b = 1 + rng.below(36) as usize;
        let b = digits(rng, len_b);
        let sa = if rng.below(2) == 0 { "" } else { "-" };
        let sb = if rng.below(2) == 0 { "" } else { "-" };
        let ea = rng.below(80) as i64 - 40;
        let eb = rng.below(80) as i64 - 40;
        let op = ["plus", "minus", "times", "div"][rng.below(4) as usize];
        out.push((op, format!("{sa}{a}e{ea}"), format!("{sb}{b}e{eb}")));
    }
    out
}
