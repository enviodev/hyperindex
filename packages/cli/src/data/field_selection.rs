use anyhow::{anyhow, Result};

use hypersync_client::net_types::FieldSelection as NetFieldSelection;

use super::mapping::{self, Section, TypedField};

#[derive(Debug, Clone, Default)]
pub struct Selection {
    pub columns: Vec<Column>,
    pub known_height: bool,
}

#[derive(Debug, Clone)]
pub struct Column {
    pub section: Section,
    pub field: TypedField,
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

            let field = mapping::lookup(section, field_raw).ok_or_else(|| {
                let valid = mapping::valid_indexer_names(section).join(", ");
                anyhow!("Unknown field `{raw}`. Valid `{section_raw}.*` fields: {valid}.")
            })?;

            sel.columns.push(Column { section, field });
        }

        Ok(sel)
    }

    pub fn has_data_fields(&self) -> bool {
        !self.columns.is_empty()
    }

    /// Builds the Hypersync field selection, also requesting `extra` fields so
    /// client-side filter fields are fetched even when not selected for output.
    pub fn build_net_field_selection_with(&self, extra: &[TypedField]) -> NetFieldSelection {
        let mut fs = NetFieldSelection::default();
        for col in &self.columns {
            insert_field(&mut fs, col.field);
        }
        for field in extra {
            insert_field(&mut fs, *field);
        }
        fs
    }
}

fn insert_field(fs: &mut NetFieldSelection, field: TypedField) {
    match field {
        TypedField::Block(f) => {
            fs.block.insert(f);
        }
        TypedField::Transaction(f) => {
            fs.transaction.insert(f);
        }
        TypedField::Log(f) => {
            fs.log.insert(f);
        }
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

        let cols: Vec<(Section, String)> = sel
            .columns
            .iter()
            .map(|c| (c.section, c.field.camel_name()))
            .collect();

        assert_eq!(
            (cols, sel.known_height),
            (
                vec![
                    (Section::Block, "number".to_string()),
                    (Section::Block, "hash".to_string()),
                    (Section::Log, "srcAddress".to_string()),
                    (Section::Transaction, "transactionIndex".to_string()),
                ],
                true,
            ),
        );
    }

    #[test]
    fn known_height_only_has_no_data_fields() {
        let sel = Selection::parse(&["knownHeight".into()]).unwrap();
        assert_eq!((sel.has_data_fields(), sel.known_height), (false, true));
    }

    #[test]
    fn rejects_missing_dot() {
        let err = Selection::parse(&["blocknumber".into()])
            .unwrap_err()
            .to_string();
        insta::assert_snapshot!(err, @r#"Bad field `blocknumber`. Use `<section>.<field>` (e.g. `block.number`) or `knownHeight`.
Valid sections: block, transaction, log."#);
    }

    #[test]
    fn rejects_unknown_section() {
        let err = Selection::parse(&["receipt.txId".into()])
            .unwrap_err()
            .to_string();
        insta::assert_snapshot!(err, @"Unknown section `receipt` in `receipt.txId`. Valid sections for this chain: block, transaction, log.");
    }

    #[test]
    fn rejects_unknown_field() {
        let err = Selection::parse(&["log.foo".into()])
            .unwrap_err()
            .to_string();
        insta::assert_snapshot!(err, @"Unknown field `log.foo`. Valid `log.*` fields: transactionHash, blockHash, blockNumber, transactionIndex, logIndex, srcAddress, data, removed, topic0, topic1, topic2, topic3.");
    }

    #[test]
    fn accepts_snake_case_fields() {
        let sel = Selection::parse(&[
            "block.gas_limit".into(),
            "log.src_address".into(),
            "transaction.transaction_index".into(),
        ])
        .unwrap();
        let names: Vec<String> = sel.columns.iter().map(|c| c.field.camel_name()).collect();
        assert_eq!(names, vec!["gasLimit", "srcAddress", "transactionIndex"]);
    }

    #[test]
    fn accepts_all_lowercase() {
        let sel = Selection::parse(&["block.gaslimit".into(), "log.blocknumber".into()]).unwrap();
        assert_eq!(sel.columns.len(), 2);
    }

    #[test]
    fn accepts_uppercase() {
        let sel = Selection::parse(&["block.GAS_LIMIT".into(), "log.TOPIC0".into()]).unwrap();
        assert_eq!(sel.columns.len(), 2);
    }
}
