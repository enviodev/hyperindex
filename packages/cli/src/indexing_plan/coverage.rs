/// Inclusive block ranges, ascending and apart.
pub(crate) type Ranges = Vec<(i64, i64)>;

/// What a need has: every block through `covered_through`, and the ranges
/// that finished ahead of it, ascending, apart from it and from each other.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Coverage {
    pub covered_through: i64,
    pub ahead: Ranges,
}

impl Coverage {
    pub fn new(covered_through: i64) -> Self {
        Self {
            covered_through,
            ahead: Vec::new(),
        }
    }

    pub fn add(&mut self, from_block: i64, to_block: i64) {
        if to_block < from_block || to_block <= self.covered_through {
            return;
        }
        if from_block <= self.covered_through + 1 {
            self.covered_through = to_block;
        } else {
            self.ahead.push((from_block, to_block));
            self.ahead = union(std::mem::take(&mut self.ahead));
        }
        while let Some(&(from, to)) = self.ahead.first() {
            if from > self.covered_through + 1 {
                break;
            }
            self.covered_through = self.covered_through.max(to);
            self.ahead.remove(0);
        }
    }

    /// Forgets everything above `block`, never going below `floor`.
    pub fn clip(&mut self, block: i64, floor: i64) {
        self.covered_through = self.covered_through.min(block).max(floor);
        let covered_through = self.covered_through;
        self.ahead.retain(|&(from, _)| from <= block);
        if let Some(last) = self.ahead.last_mut() {
            last.1 = last.1.min(block);
        }
        self.ahead.retain(|&(_, to)| to > covered_through);
    }

    /// The highest block anything has covered.
    pub fn highest(&self) -> i64 {
        self.ahead
            .last()
            .map_or(self.covered_through, |&(_, to)| to)
    }

    /// Everything covered, `covered_through` as a range from the chain start.
    pub fn ranges(&self) -> Ranges {
        let mut ranges = Vec::with_capacity(self.ahead.len() + 1);
        ranges.push((i64::MIN, self.covered_through));
        ranges.extend_from_slice(&self.ahead);
        ranges
    }
}

/// The union of ranges in any order, as ascending ranges apart.
pub(crate) fn union(mut ranges: Ranges) -> Ranges {
    ranges.sort_unstable();
    let mut merged: Ranges = Vec::with_capacity(ranges.len());
    for (from, to) in ranges {
        match merged.last_mut() {
            Some(last) if from <= last.1.saturating_add(1) => last.1 = last.1.max(to),
            _ => merged.push((from, to)),
        }
    }
    merged
}

/// The blocks in both, for ascending ranges apart.
pub(crate) fn intersection(a: &[(i64, i64)], b: &[(i64, i64)]) -> Ranges {
    let (mut i, mut j) = (0, 0);
    let mut result = Vec::new();
    while i < a.len() && j < b.len() {
        let from = a[i].0.max(b[j].0);
        let to = a[i].1.min(b[j].1);
        if from <= to {
            result.push((from, to));
        }
        if a[i].1 < b[j].1 {
            i += 1;
        } else {
            j += 1;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds_ranges_ahead_and_joins_them_once_the_gap_fills() {
        let mut coverage = Coverage::new(9);
        coverage.add(21, 30);
        coverage.add(41, 50);
        coverage.add(31, 35);
        assert_eq!(
            coverage,
            Coverage {
                covered_through: 9,
                ahead: vec![(21, 35), (41, 50)]
            }
        );
        coverage.add(10, 20);
        assert_eq!(
            coverage,
            Coverage {
                covered_through: 35,
                ahead: vec![(41, 50)]
            }
        );
    }

    #[test]
    fn clips_to_a_block_above_its_floor() {
        let mut coverage = Coverage {
            covered_through: 35,
            ahead: vec![(41, 50), (61, 70)],
        };
        coverage.clip(45, 0);
        assert_eq!(
            coverage,
            Coverage {
                covered_through: 35,
                ahead: vec![(41, 45)]
            }
        );
        coverage.clip(20, 25);
        assert_eq!(coverage, Coverage::new(25));
    }

    #[test]
    fn intersects_and_unites_ranges() {
        assert_eq!(
            intersection(&[(i64::MIN, 10), (20, 30)], &[(i64::MIN, 25)]),
            vec![(i64::MIN, 10), (20, 25)]
        );
        assert_eq!(
            union(vec![(20, 30), (i64::MIN, 10), (11, 15), (25, i64::MAX)]),
            vec![(i64::MIN, 15), (20, i64::MAX)]
        );
    }
}
