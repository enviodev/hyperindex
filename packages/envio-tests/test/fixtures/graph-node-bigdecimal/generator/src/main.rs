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
        let (x, y) = (normalized(Old::from_str(&a).unwrap()), normalized(Old::from_str(&b).unwrap()));
        let (op, result) = match i % 5 {
            0 => ("plus", normalized(x + y)),
            1 => ("minus", normalized(x - y)),
            2 => ("times", normalized(x * y)),
            3 => ("div", normalized(x / y)),
            _ => ("parse", x),
        };
        lines.push(format!("  [\"{op}\", \"{a}\", \"{b}\", \"{result}\"]"));
    }
    println!("[\n{}\n]", lines.join(",\n"));
}
