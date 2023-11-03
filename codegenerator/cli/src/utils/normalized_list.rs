use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(untagged)]
enum SingleOrList<T: Clone> {
    Single(T),
    List(Vec<T>),
}

impl<T: Clone> From<SingleOrList<T>> for Vec<T> {
    fn from(single_or_list: SingleOrList<T>) -> Self {
        match single_or_list {
            SingleOrList::Single(v) => vec![v],
            SingleOrList::List(l) => l,
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct OptSingleOrList<T: Clone>(Option<SingleOrList<T>>);

impl<T: Clone> From<OptSingleOrList<T>> for Vec<T> {
    fn from(single_or_list: OptSingleOrList<T>) -> Self {
        single_or_list.0.map_or_else(|| vec![], |v| v.into())
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(from = "OptSingleOrList<T>")]
pub struct NormalizedList<T: Clone>(Vec<T>);

impl<T: Clone> From<OptSingleOrList<T>> for NormalizedList<T> {
    fn from(single_or_list: OptSingleOrList<T>) -> Self {
        NormalizedList(single_or_list.0.map_or_else(|| vec![], |v| v.into()))
    }
}

impl<T: Clone> From<NormalizedList<T>> for Vec<T> {
    fn from(normalized_list: NormalizedList<T>) -> Self {
        normalized_list.0
    }
}
impl<T: Clone> From<Vec<T>> for NormalizedList<T> {
    fn from(v: Vec<T>) -> Self {
        NormalizedList(v)
    }
}

impl<T: Clone> IntoIterator for NormalizedList<T> {
    type Item = T;
    type IntoIter = std::vec::IntoIter<T>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}
