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
