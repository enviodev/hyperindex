use anyhow::anyhow;
use std::collections::HashMap;

pub fn try_insert<K, V>(map: &mut HashMap<K, V>, key: K, val: V) -> anyhow::Result<()>
where
    K: std::cmp::Eq + std::hash::Hash + std::fmt::Display,
{
    match map.get(&key) {
        //If value exists, error without updating
        Some(_) => Err(anyhow!("{} already exists, cannot have duplicates", key,)),
        None => {
            //If not insert it
            map.insert(key, val);
            Ok(())
        }
    }
}

pub fn from_vec_no_duplicates<K, V>(v: Vec<(K, V)>) -> anyhow::Result<HashMap<K, V>>
where
    K: std::cmp::Eq + std::hash::Hash + std::fmt::Display,
{
    let mut map = HashMap::new();

    for (key, val) in v {
        try_insert(&mut map, key, val)?
    }

    Ok(map)
}
