use anyhow::{anyhow, Result};

use hypersync_client::net_types::FieldSelection as NetFieldSelection;

use super::mapping::{self, Section, TypedField};

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
    pub typed_field: Option<TypedField>,
}

impl Selection {
    pub fn parse(positionals: &[String]) -> Result<Self> {
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
                    sections = mapping::ALLOWED_SECTIONS.join(", "),
                )
            })?;

            let section = mapping::parse_section(section_raw).ok_or_else(|| {
                anyhow!(
                    "Unknown section `{section_raw}` in `{raw}`. Valid sections for this chain: {sections}.",
                    sections = mapping::ALLOWED_SECTIONS.join(", "),
                )
            })?;

            let entry = mapping::lookup(section, field_raw).ok_or_else(|| {
                let valid = mapping::valid_indexer_names(section).join(", ");
                anyhow!("Unknown field `{raw}`. Valid `{section_raw}.*` fields: {valid}.")
            })?;

            sel.columns.push(Column {
                section,
                indexer_name: field_raw.to_string(),
                hs_name: entry.hs_name.to_string(),
                typed_field: entry.typed_field,
            });
        }

        Ok(sel)
    }

    /// Whether at least one real (non-knownHeight) field was requested.
    pub fn has_data_fields(&self) -> bool {
        !self.columns.is_empty()
    }

    /// Builds a typed `FieldSelection` for the native hypersync client.
    pub fn build_net_field_selection(&self) -> NetFieldSelection {
        let mut fs = NetFieldSelection::default();
        for col in &self.columns {
            match col.typed_field {
                Some(TypedField::Block(f)) => {
                    fs.block.insert(f);
                }
                Some(TypedField::Transaction(f)) => {
                    fs.transaction.insert(f);
                }
                Some(TypedField::Log(f)) => {
                    fs.log.insert(f);
                }
                None => {}
            }
        }
        fs
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn parses_fields_and_known_height() {
        let sel = Selection::parse(&[
            "block.number".into(),
            "block.hash".into(),
            "log.srcAddress".into(),
            "transaction.transactionIndex".into(),
            "knownHeight".into(),
        ])
        .unwrap();

        let cols: Vec<(Section, String, String)> = sel
            .columns
            .iter()
            .map(|c| (c.section, c.indexer_name.clone(), c.hs_name.clone()))
            .collect();

        assert_eq!(
            (cols, sel.known_height),
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
            ),
        );
    }

    #[test]
    fn known_height_only_has_no_data_fields() {
        let sel = Selection::parse(&["knownHeight".into()]).unwrap();
        assert_eq!((sel.has_data_fields(), sel.known_height), (false, true),);
    }

    #[test]
    fn rejects_missing_dot() {
        let err = Selection::parse(&["blocknumber".into()])
            .unwrap_err()
            .to_string();
        assert!(err.contains("Bad field"), "{err}");
    }

    #[test]
    fn rejects_unknown_section() {
        let err = Selection::parse(&["receipt.txId".into()])
            .unwrap_err()
            .to_string();
        assert!(err.contains("Unknown section"), "{err}");
    }

    #[test]
    fn rejects_unknown_field() {
        let err = Selection::parse(&["log.foo".into()])
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("Unknown field") && err.contains("srcAddress"),
            "{err}"
        );
    }
}
