use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(untagged)]
pub enum SingleOrList<T: Clone> {
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

impl<T: Clone> From<Vec<T>> for SingleOrList<T> {
    fn from(v: Vec<T>) -> Self {
        SingleOrList::List(v)
    }
}
impl<T: Clone> From<T> for SingleOrList<T> {
    fn from(v: T) -> Self {
        SingleOrList::Single(v)
    }
}

type OptSingleOrList<T> = Option<SingleOrList<T>>;

#[derive(Debug, Deserialize, Serialize, Clone, PartialEq)]
#[serde(from = "OptSingleOrList<T>")]
pub struct NormalizedList<T: Clone>(Vec<T>);

impl<T: Clone> NormalizedList<T> {
    pub fn is_empty(&self) -> bool {
        self.0.len() == 0
    }
}

impl<T: Clone> From<OptSingleOrList<T>> for NormalizedList<T> {
    fn from(single_or_list: OptSingleOrList<T>) -> Self {
        NormalizedList(single_or_list.map_or_else(|| vec![], |v| v.into()))
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
impl<T: Clone> From<T> for NormalizedList<T> {
    fn from(v: T) -> Self {
        NormalizedList(vec![v])
    }
}

impl<T: Clone> IntoIterator for NormalizedList<T> {
    type Item = T;
    type IntoIter = std::vec::IntoIter<T>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}

#[cfg(test)]
mod test {
    use super::{NormalizedList, OptSingleOrList};
    use serde::Deserialize;

    #[derive(Debug, Deserialize, PartialEq)]
    struct TestStruct {
        val: i32,
        list_val: NormalizedList<i32>,
    }
    #[derive(Debug, Deserialize, PartialEq)]
    struct TestStruct2 {
        val: i32,
        list_val: OptSingleOrList<i32>,
    }

    #[test]
    fn deserializes_from_list() {
        let json = r#"{"val": 1, "list_val": [2]}"#;
        let de: TestStruct = serde_json::from_str(json).unwrap();
        let expected = TestStruct {
            val: 1,
            list_val: vec![2].into(),
        };
        assert_eq!(expected, de);
    }

    #[test]
    fn deserializes_from_single() {
        let json = r#"{"val": 1, "list_val": 2}"#;
        let de: TestStruct = serde_json::from_str(json).unwrap();
        let expected = TestStruct {
            val: 1,
            list_val: vec![2].into(),
        };
        assert_eq!(expected, de);
    }

    #[test]
    fn deserializes_from_none() {
        let json = r#"{"val": 1}"#;
        let de: TestStruct = serde_json::from_str(json).unwrap();
        let expected = TestStruct {
            val: 1,
            list_val: vec![].into(),
        };
        assert_eq!(expected, de);
    }

    #[test]
    fn deserializes_opt_single_list_from_none() {
        let json = r#"{"val": 1}"#;
        let de: TestStruct2 = serde_json::from_str(json).unwrap();
        let expected = TestStruct2 {
            val: 1,
            list_val: None,
        };
        assert_eq!(expected, de);
    }
}
