use crate::{capitalization::Capitalize, RecordType};
use std::collections::HashMap;

#[derive(PartialEq, Clone)]
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

#[derive(Clone)]
struct HeadAndTail<K> {
    head_key: K,
    tail_key: K,
}

pub struct LinkedHashMap<K, T> {
    head_and_tail: Option<HeadAndTail<K>>,
    map: HashMap<K, Node<K, T>>,
}

type RescriptTypeName = String;

#[derive(Eq, Hash, PartialEq, Clone)]
pub struct RescriptRecordKey {
    key: RescriptTypeName,
    number_of_matching_keys: i32,
}

impl RescriptRecordKey {
    fn new(key: String) -> RescriptRecordKey {
        RescriptRecordKey {
            key,
            number_of_matching_keys: 0,
        }
    }

    fn concat_key_and_count(&self) -> String {
        if self.number_of_matching_keys > 0 {
            format!("{}_{}", self.key, self.number_of_matching_keys)
        } else {
            self.key.clone()
        }
    }
}

pub type RescripRecordHirarchyLinkedHashMap = LinkedHashMap<RescriptRecordKey, RecordType>;

pub struct RescripRecordHirarchyLinkedHashMapIterator<'a> {
    linked_hash_map: &'a RescripRecordHirarchyLinkedHashMap,
    next_key: Option<RescriptRecordKey>,
}

impl<'a> Iterator for RescripRecordHirarchyLinkedHashMapIterator<'a> {
    type Item = RecordType;
    fn next(&mut self) -> Option<Self::Item> {
        match &self.next_key {
            None => None,
            Some(next_key) => {
                let next_node = self.linked_hash_map.map.get(&next_key);
                //the
                next_node.map(|node| {
                    self.next_key = node.next_key.to_owned();
                    node.data.to_owned()
                })
            }
        }
    }
}

enum HashMapKeyInsert<K> {
    ExistingKeyAndEntry(K),
    UpdatedKeyNewEntry(K),
    NewKeyAndEntry(K),
}

impl RescripRecordHirarchyLinkedHashMap {
    pub fn new() -> RescripRecordHirarchyLinkedHashMap {
        LinkedHashMap {
            head_and_tail: None,
            map: HashMap::new(),
        }
    }

    fn insert_into_map_or_increment_key(
        &mut self,
        key: RescriptRecordKey,
        node: &mut Node<RescriptRecordKey, RecordType>,
    ) -> HashMapKeyInsert<RescriptRecordKey> {
        //check for existing values (need to actually look up the value for equality comparison)
        match self.map.get(&key) {
            Some(existing_value) => {
                //if the existing value matches the current node exactly
                //do not update it or do anything simply return since this type
                //can be reused
                if existing_value == node {
                    return HashMapKeyInsert::ExistingKeyAndEntry(key);
                }

                //Otherwise increment the type ie. myType becomes myType_1
                let new_key = RescriptRecordKey {
                    number_of_matching_keys: key.number_of_matching_keys + 1,
                    ..key
                };

                //Change the name in the record as well
                node.data.name = new_key.concat_key_and_count().to_capitalized_options();

                self.insert_into_map_or_increment_key(new_key, node)
            }
            None => {
                //If the key doesn't exist safely insert it to the map
                self.map.insert(key.clone(), node.to_owned());
                if key.number_of_matching_keys > 0 {
                    HashMapKeyInsert::UpdatedKeyNewEntry(key)
                } else {
                    HashMapKeyInsert::NewKeyAndEntry(key)
                }
            }
        }
    }

    pub fn insert(&mut self, key: String, value: RecordType) -> RescriptTypeName {
        //Instantiate a node with the given value
        let mut node = Node::new(value);
        //Try insert it to the map (it will either already exist, create a new name/key or insert
        //successfully)
        let node_key_insert =
            self.insert_into_map_or_increment_key(RescriptRecordKey::new(key), &mut node);

        //match on whether there is an existing head/tail
        //ie whether this is the first item in the map
        match &self.head_and_tail {
            None => match node_key_insert {
                //This case should never happen since a None head_and_tail would indicate
                //the map is empty
                HashMapKeyInsert::ExistingKeyAndEntry(key) => key.concat_key_and_count(),
                //If it is an updated or new entry set the head and tail
                HashMapKeyInsert::UpdatedKeyNewEntry(key)
                | HashMapKeyInsert::NewKeyAndEntry(key) => {
                    self.head_and_tail = Some(HeadAndTail {
                        head_key: key.clone(),
                        tail_key: key.clone(),
                    });
                    //return a string version of the updated key
                    //eg {key: "myType", number_of_matching_keys: 0} becomes myType
                    //and {key: "myType", number_of_matching_keys: 1} becomes myType_1
                    key.concat_key_and_count()
                }
            },
            //A Some case would mean there is an item in the map
            Some(HeadAndTail { head_key, tail_key }) => match node_key_insert {
                //If the type exists do not update head or tail
                //the existing type should exist higher up the hirarcheacle list and will
                //be available to anything needed below
                HashMapKeyInsert::ExistingKeyAndEntry(key) => key.concat_key_and_count(),
                HashMapKeyInsert::UpdatedKeyNewEntry(key)
                | HashMapKeyInsert::NewKeyAndEntry(key) => {
                    //After inserting a new node successfully update it to contain
                    //the next_key as the current_head key
                    let new_node_entry_opt = self.map.get_mut(&key);
                    if let Some(new_node_entry) = new_node_entry_opt {
                        new_node_entry.next_key = Some(head_key.clone());
                    }
                    //update the current head_key to the new node key
                    self.head_and_tail = Some(HeadAndTail {
                        head_key: key.clone(),
                        tail_key: tail_key.clone(),
                    });
                    key.concat_key_and_count()
                }
            },
        }
    }
    pub fn iter(&self) -> RescripRecordHirarchyLinkedHashMapIterator {
        let next_key = self
            .head_and_tail
            .clone()
            .map(|head_and_tail| head_and_tail.head_key);

        RescripRecordHirarchyLinkedHashMapIterator {
            linked_hash_map: &self,
            next_key,
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::{capitalization::Capitalize, ParamType, RecordType};

    use super::RescripRecordHirarchyLinkedHashMap;

    #[test]
    fn different_rescript_records() {
        let name_1 = String::from("test1");
        let record_1 = RecordType {
            name: name_1.to_capitalized_options(),
            params: Vec::new(),
        };

        let name_2 = String::from("test2");
        let record_2 = RecordType {
            name: name_2.to_capitalized_options(),
            params: Vec::new(),
        };

        let name_3 = String::from("test3");
        let record_3 = RecordType {
            name: name_3.to_capitalized_options(),
            params: Vec::new(),
        };

        let mut linked_table = RescripRecordHirarchyLinkedHashMap::new();
        linked_table.insert(name_1, record_1.clone());
        linked_table.insert(name_2, record_2.clone());
        linked_table.insert(name_3, record_3.clone());

        let expected_records_arr = vec![record_3, record_2, record_1];
        let records_arr = linked_table.iter().collect::<Vec<RecordType>>();
        assert_eq!(expected_records_arr, records_arr);
    }

    #[test]
    fn different_rescript_records_same_name() {
        let name_1 = String::from("test1");
        let record_1 = RecordType {
            name: name_1.to_capitalized_options(),
            params: Vec::new(),
        };

        let name_2 = String::from("test1");
        let record_2 = RecordType {
            name: name_2.to_capitalized_options(),
            params: vec![ParamType {
                key: String::from("test_key1"),
                type_: String::from("test_type1"),
            }],
        };

        let name_3 = String::from("test3");
        let record_3 = RecordType {
            name: name_3.to_capitalized_options(),
            params: Vec::new(),
        };

        let mut linked_table = RescripRecordHirarchyLinkedHashMap::new();
        linked_table.insert(name_1, record_1.clone());
        linked_table.insert(name_2, record_2.clone());
        linked_table.insert(name_3, record_3.clone());

        let expected_records_arr = vec![
            record_3,
            RecordType {
                name: String::from("test1_1").to_capitalized_options(),
                ..record_2
            },
            record_1,
        ];
        let records_arr = linked_table.iter().collect::<Vec<RecordType>>();
        assert_eq!(expected_records_arr, records_arr);
    }

    #[test]
    fn different_rescript_records_same_name_and_val() {
        let name_1 = String::from("test1");
        let record_1 = RecordType {
            name: name_1.to_capitalized_options(),
            params: Vec::new(),
        };

        let name_2 = String::from("test1");
        let record_2 = RecordType {
            name: name_2.to_capitalized_options(),
            params: vec![ParamType {
                key: String::from("test_key1"),
                type_: String::from("test_type1"),
            }],
        };

        let name_3 = String::from("test1");
        let record_3 = RecordType {
            name: name_3.to_capitalized_options(),
            params: Vec::new(),
        };

        let mut linked_table = RescripRecordHirarchyLinkedHashMap::new();
        linked_table.insert(name_1, record_1.clone());
        linked_table.insert(name_2, record_2.clone());
        linked_table.insert(name_3, record_3.clone());

        let expected_records_arr = vec![
            RecordType {
                name: String::from("test1_1").to_capitalized_options(),
                ..record_2
            },
            record_1,
        ];

        let records_arr = linked_table.iter().collect::<Vec<RecordType>>();
        assert_eq!(expected_records_arr, records_arr);
    }
}
