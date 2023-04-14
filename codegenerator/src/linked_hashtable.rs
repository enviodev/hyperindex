use crate::RecordType;
use std::collections::HashMap;

#[derive(PartialEq)]
struct Node<K, T> {
    data: T,
    next_key: Option<K>,
}

impl<K, T> Node<K, T> {
    fn new(data: T) -> Node<K, T> {
        Node {
            data,
            next_key: None,
        }
    }
}

struct HeadAndTail<K> {
    head_key: K,
    tail_key: K,
}

struct LinkedHashMap<K, T> {
    head_and_tail: Option<HeadAndTail<K>>,
    size: usize,
    map: HashMap<K, Node<K, T>>,
}

type RescripRecordHirarchyLinkedHashMap = LinkedHashMap<String, RecordType>;

// impl<K, T> LinkedHashMap<K, T>
// where
//     K: Eq + PartialEq + Hash + Clone,
//     T: PartialEq + Clone,
// {
//     fn new() -> LinkedHashMap<K, T> {
//         LinkedHashMap {
//             head_key: None,
//             size: 0,
//             map: HashMap::new(),
//         }
//     }
//
//     fn add_to_head(&mut self, key: K, value: T) -> bool {
//         // let mut map = self.map;
//         let new_node = Node::new(value.clone());
//
//         let inserted_node = self.map.entry(key.clone()).or_insert(new_node);
//
//         if inserted_node.data != value {
//             false
//         } else {
//             match self.head_key {
//                 None => (),
//                 Some(head_key) => {
//                     let current_head = self
//                         .map
//                         .get_mut(&head_key)
//                         .expect("Key was set so there should be a node at this key");
//                     current_head.next_key = Some(key.clone());
//                 }
//             }
//             self.head_key = Some(key);
//             true
//         }
//     }
// }
impl RescripRecordHirarchyLinkedHashMap {
    fn new() -> RescripRecordHirarchyLinkedHashMap {
        LinkedHashMap {
            head_and_tail: None,
            size: 0,
            map: HashMap::new(),
        }
    }

    fn insert(&mut self, key: String, value: RecordType) -> bool {
        // let mut map = self.map;
        match (self.head_key, self.tail_key) {
            (None, None) => (),          // set both vals as the new node,
            (Some(current_head),) => (), // set both vals as the new node,
        }
        let new_node = Node::new(value.clone());

        let inserted_node = self.map.entry(key.clone()).or_insert(new_node);

        if inserted_node.data != value {
            false
        } else {
            match self.head_key {
                None => (),
                Some(head_key) => {
                    let current_head = self
                        .map
                        .get_mut(&head_key)
                        .expect("Key was set so there should be a node at this key");
                    current_head.next_key = Some(key.clone());
                }
            }
            self.head_key = Some(key);
            true
        }
    }
}
