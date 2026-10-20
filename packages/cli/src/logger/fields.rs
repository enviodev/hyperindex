use serde::de::{Deserialize, Deserializer, MapAccess, Visitor};
use serde_json::value::RawValue;
use std::fmt;

/// An object's entries in the order written, each value left as the JSON text
/// it arrived as: a line's fields are only ever copied into the output, so
/// nothing parses them unless a format has to look inside.
pub type Fields = Vec<(String, Box<RawValue>)>;

struct Entries(Fields);

impl<'de> Deserialize<'de> for Entries {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct EntriesVisitor;
        impl<'de> Visitor<'de> for EntriesVisitor {
            type Value = Entries;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("a JSON object")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Entries, A::Error> {
                let mut entries = Vec::with_capacity(map.size_hint().unwrap_or(4));
                while let Some(entry) = map.next_entry()? {
                    entries.push(entry);
                }
                Ok(Entries(entries))
            }
        }
        deserializer.deserialize_map(EntriesVisitor)
    }
}

/// JSON a caller handed over as an object; `null` is no fields, and anything
/// else is kept under `params`, so a line never loses what it was given.
pub fn parse_object_fields(json: &str) -> Result<Fields, serde_json::Error> {
    match json.trim_start().as_bytes().first() {
        Some(b'{') => serde_json::from_str::<Entries>(json).map(|entries| entries.0),
        _ => {
            let raw: Box<RawValue> = serde_json::from_str(json)?;
            Ok(if raw.get() == "null" {
                Vec::new()
            } else {
                vec![("params".to_string(), raw)]
            })
        }
    }
}

/// Every layer's entries, a later layer's value replacing an earlier one's
/// under the same key while the key keeps the place it was first given.
pub fn merge_later_wins<'a>(
    layers: &[&'a [(String, Box<RawValue>)]],
) -> Vec<(&'a str, &'a RawValue)> {
    let mut merged: Vec<(&str, &RawValue)> =
        Vec::with_capacity(layers.iter().map(|layer| layer.len()).sum());
    for layer in layers {
        for (key, value) in layer.iter() {
            match merged.iter_mut().find(|(existing, _)| *existing == key) {
                Some(slot) => slot.1 = value,
                None => merged.push((key, value)),
            }
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rendered(merged: &[(&str, &RawValue)]) -> Vec<(String, String)> {
        merged
            .iter()
            .map(|(key, value)| (key.to_string(), value.get().to_string()))
            .collect()
    }

    #[test]
    fn later_layers_replace_values_in_the_first_place_given() {
        let bindings = parse_object_fields(r#"{"chainId":1,"source":"a","source":"b"}"#).unwrap();
        let params = parse_object_fields(r#"{"chainId":2,"n":{"deep":[1,2]}}"#).unwrap();
        assert_eq!(
            rendered(&merge_later_wins(&[&bindings, &params])),
            vec![
                ("chainId".into(), "2".into()),
                ("source".into(), r#""b""#.into()),
                ("n".into(), r#"{"deep":[1,2]}"#.into()),
            ]
        );
    }

    #[test]
    fn keeps_a_non_object_under_params_and_null_as_nothing() {
        assert_eq!(
            (
                rendered(&merge_later_wins(&[
                    &parse_object_fields(r#""text""#).unwrap()
                ])),
                parse_object_fields(" null").unwrap().len()
            ),
            (vec![("params".into(), r#""text""#.into())], 0)
        );
    }
}
