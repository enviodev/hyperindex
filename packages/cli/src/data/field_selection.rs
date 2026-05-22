use anyhow::{anyhow, Result};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

use super::chain::ChainKind;
use super::mapping::{self, Section};

/// Parsed positional fields.
#[derive(Debug, Clone, Default)]
pub struct Selection {
    /// Preserves the user's input order, used for TOON column order.
    pub columns: Vec<Column>,
    pub known_height: bool,
}

#[derive(Debug, Clone)]
pub struct Column {
    pub section: Section,
    pub indexer_name: String,
    pub hs_name: String,
}

impl Selection {
    pub fn parse(kind: ChainKind, positionals: &[String]) -> Result<Self> {
        if positionals.is_empty() {
            return Err(anyhow!(
                "No fields requested. Pass at least one field like `block.number` or `knownHeight`."
            ));
        }

        let mut sel = Selection::default();
        for raw in positionals {
            if raw == "knownHeight" {
                sel.known_height = true;
                continue;
            }

            let (section_raw, field_raw) = raw.split_once('.').ok_or_else(|| {
                anyhow!(
                    "Bad field `{raw}`. Use `<section>.<field>` (e.g. `block.number`) or `knownHeight`.\n\
                     Valid sections: {sections}.",
                    sections = mapping::allowed_sections(kind).join(", "),
                )
            })?;

            let section = mapping::parse_section(kind, section_raw).ok_or_else(|| {
                anyhow!(
                    "Unknown section `{section_raw}` in `{raw}`. Valid sections for this chain: {sections}.",
                    sections = mapping::allowed_sections(kind).join(", "),
                )
            })?;

            let entry = mapping::lookup(kind, section, field_raw).ok_or_else(|| {
                let valid = mapping::valid_indexer_names(kind, section).join(", ");
                anyhow!("Unknown field `{raw}`. Valid `{section_raw}.*` fields: {valid}.")
            })?;

            sel.columns.push(Column {
                section,
                indexer_name: field_raw.to_string(),
                hs_name: entry.hs_name.to_string(),
            });
        }

        Ok(sel)
    }

    /// Whether at least one real (non-knownHeight) field was requested.
    pub fn has_data_fields(&self) -> bool {
        !self.columns.is_empty()
    }

    /// Builds the `field_selection` object for the HS query body.
    /// Returns an empty object when no real fields were requested.
    pub fn build_field_selection(&self) -> Value {
        let mut by_section: BTreeMap<&'static str, Vec<Value>> = BTreeMap::new();
        for col in &self.columns {
            by_section
                .entry(col.section.as_hs_key())
                .or_default()
                .push(Value::String(col.hs_name.clone()));
        }
        let mut out = Map::new();
        for (k, v) in by_section {
            out.insert(k.to_string(), json!(v));
        }
        Value::Object(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn parses_evm_fields_and_known_height() {
        let sel = Selection::parse(
            ChainKind::Evm,
            &[
                "block.number".into(),
                "block.hash".into(),
                "log.srcAddress".into(),
                "transaction.transactionIndex".into(),
                "knownHeight".into(),
            ],
        )
        .unwrap();

        let cols: Vec<(Section, String, String)> = sel
            .columns
            .iter()
            .map(|c| (c.section, c.indexer_name.clone(), c.hs_name.clone()))
            .collect();

        assert_eq!(
            (cols, sel.known_height, sel.build_field_selection()),
            (
                vec![
                    (Section::Block, "number".into(), "number".into()),
                    (Section::Block, "hash".into(), "hash".into()),
                    (Section::Log, "srcAddress".into(), "address".into()),
                    (
                        Section::Transaction,
                        "transactionIndex".into(),
                        "transaction_index".into()
                    ),
                ],
                true,
                json!({
                    "block": ["number", "hash"],
                    "log": ["address"],
                    "transaction": ["transaction_index"],
                }),
            ),
        );
    }

    #[test]
    fn known_height_only_has_no_data_fields() {
        let sel = Selection::parse(ChainKind::Evm, &["knownHeight".into()]).unwrap();
        assert_eq!((sel.has_data_fields(), sel.known_height), (false, true),);
    }

    #[test]
    fn rejects_missing_dot() {
        let err = Selection::parse(ChainKind::Evm, &["blocknumber".into()])
            .unwrap_err()
            .to_string();
        assert!(err.contains("Bad field"), "{err}");
    }

    #[test]
    fn rejects_unknown_section_for_chain() {
        let err = Selection::parse(ChainKind::Evm, &["receipt.txId".into()])
            .unwrap_err()
            .to_string();
        assert!(err.contains("Unknown section"), "{err}");
    }

    #[test]
    fn rejects_unknown_field() {
        let err = Selection::parse(ChainKind::Evm, &["log.foo".into()])
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("Unknown field") && err.contains("srcAddress"),
            "{err}"
        );
    }

    #[test]
    fn fuel_accepts_receipt_and_block_height() {
        let sel = Selection::parse(
            ChainKind::Fuel,
            &["block.height".into(), "receipt.contractId".into()],
        )
        .unwrap();
        assert_eq!(
            sel.build_field_selection(),
            json!({
                "block": ["height"],
                "receipt": ["contract_id"],
            }),
        );
    }
}
