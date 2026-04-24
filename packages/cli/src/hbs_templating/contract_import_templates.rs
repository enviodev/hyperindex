///Helpers for enumerating event params with their original positional index.
///Tuple params (including `tuple[]` / `tuple[N]`) are kept intact as single
///entity fields typed as JSON — the handler just assigns the whole value
///through a magic cast and the entity column stores the nested object as
///JSON. This keeps the contract-import path uniform for every ABI type
///without having to invent column names for nested struct fields.
mod nested_params {
    use super::*;
    #[cfg(test)]
    use crate::config_parsing::abi_compat::AbiType;
    use crate::config_parsing::abi_compat::EventParam;

    ///Positional wrapper around an `EventParam`. Retained as a module boundary
    ///so the rest of the template code can depend on a stable shape even if
    ///the enumeration logic grows in the future.
    #[derive(Debug, Clone, PartialEq)]
    pub struct FlattenedEventParam {
        pub event_param_pos: usize,
        pub event_param: EventParam,
    }

    impl FlattenedEventParam {
        ///Gets a named parameter or constructs a name using the parameter's index
        ///if the param is nameless
        fn get_param_name(&self) -> String {
            match &self.event_param.name {
                name if name.is_empty() => format!("_{}", self.event_param_pos),
                name => name.clone(),
            }
        }

        ///Key to use for the generated entity column. Same as the event param
        ///name in almost all cases; `id` is renamed to `event_id` because `id`
        ///is reserved for the entity primary key.
        pub fn get_entity_key(&self) -> CapitalizedOptions {
            let mut entity_key = self.get_param_name();
            if entity_key == "id" {
                entity_key = "event_id".to_string();
            }
            entity_key.to_capitalized_options()
        }

        ///Key used to access the param on the runtime event object. Always the
        ///param name; only differs from `get_entity_key` when the entity key
        ///was renamed.
        pub fn get_event_param_key(&self) -> CapitalizedOptions {
            self.get_param_name().to_capitalized_options()
        }

        ///Used for constructing in tests
        #[cfg(test)]
        pub fn new(name: &str, kind: AbiType, indexed: bool, event_param_pos: usize) -> Self {
            FlattenedEventParam {
                event_param_pos,
                event_param: EventParam {
                    name: name.to_string(),
                    kind,
                    indexed,
                },
            }
        }
    }

    pub fn flatten_event_inputs(event_inputs: Vec<EventParam>) -> Vec<FlattenedEventParam> {
        event_inputs
            .into_iter()
            .enumerate()
            .map(|(i, event_input)| FlattenedEventParam {
                event_param_pos: i,
                event_param: event_input,
            })
            .collect()
    }
}

use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::{
    cli_args::init_config::Language,
    config_parsing::{
        entity_parsing::{Field, FieldType},
        event_parsing::abi_to_rescript_type,
        system_config::{self, Ecosystem, EventKind, SystemConfig},
    },
    template_dirs::TemplateDirs,
    type_schema::RecordField,
    utils::text::{Capitalize, CapitalizedOptions},
};
use anyhow::{Context, Result};
use nested_params::{flatten_event_inputs, FlattenedEventParam};
use serde::Serialize;
use std::{path::Path, vec};

///The struct that houses all the details of each contract necessary for
///populating the contract import templates
#[derive(Serialize)]
pub struct AutoSchemaHandlerTemplate {
    imported_contracts: Vec<Contract>,
    envio_api_token: Option<String>,
    first_chain_id: u64,
}

#[derive(Serialize)]
pub struct Contract {
    name: CapitalizedOptions,
    imported_events: Vec<Event>,
}

impl Contract {
    fn from_config_contract(
        contract: &system_config::Contract,
        is_fuel: bool,
        language: &Language,
    ) -> Result<Self> {
        let mut imported_events = Vec::new();

        for event in &contract.events {
            match Event::from_config_event(event, contract, is_fuel, language) {
                Ok(Some(ev)) => imported_events.push(ev),
                Ok(None) => {
                    // Event was skipped due to unsupported types - warning already logged
                }
                Err(e) => {
                    // Log warning and skip this event instead of failing the whole import
                    eprintln!(
                        "Warning: Skipping event '{}' in contract '{}': {}",
                        event.name, contract.name, e
                    );
                }
            }
        }

        if imported_events.is_empty() {
            return Err(anyhow::anyhow!(
                "No events could be imported for contract '{}'. All events have unsupported parameter types.",
                contract.name
            ));
        }

        Ok(Contract {
            name: contract.name.to_capitalized_options(),
            imported_events,
        })
    }

    /// Generates TypeScript handler file content for this contract
    pub fn generate_typescript_handler_content(&self, _is_fuel: bool) -> String {
        let mut content = String::new();

        // Header comment
        content.push_str("/*\n");
        content.push_str(" * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features\n");
        content.push_str(" */\n");

        // Import the indexer instance
        content.push_str("import { indexer } from \"generated\";\n");

        // Import type statement for entity types
        if !self.imported_events.is_empty() {
            content.push_str("import type {\n");
            for event in &self.imported_events {
                content.push_str(&format!("  {}_{},\n", self.name.capitalized, event.name));
            }
            content.push_str("} from \"generated\";\n");
        }

        // Handler registrations using indexer.onEvent
        for event in &self.imported_events {
            content.push('\n');
            content.push_str(&format!(
                "indexer.onEvent({{ contract: \"{}\", event: \"{}\" }}, async ({{ event, context }}) => {{\n",
                self.name.capitalized, event.name
            ));
            content.push_str(&format!(
                "  const entity: {}_{} = {{\n",
                self.name.capitalized, event.name
            ));
            content.push_str(&format!("    id: {},\n", event.entity_id_from_event_code));

            // Add params. Tuple params (including `tuple[]`) flow through as
            // JSON entity columns — TypeScript's `unknown` trivially accepts
            // the structured event param value, so no cast is needed.
            for param in &event.params {
                let value = format!("event.params.{}", param.event_key.original);
                content.push_str(&format!(
                    "    {}: {},\n",
                    param.entity_key.uncapitalized, value
                ));
            }

            content.push_str("  };\n\n");
            content.push_str(&format!(
                "  context.{}_{}.set(entity);\n",
                self.name.capitalized, event.name
            ));
            content.push_str("});\n");
        }

        content
    }

    /// Generates ReScript handler file content for this contract
    pub fn generate_rescript_handler_content(&self, _is_fuel: bool) -> String {
        let mut content = String::new();

        // Header comment
        content.push_str("/*\n");
        content.push_str(" * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features\n");
        content.push_str(" */\n");
        content.push('\n');
        content.push_str("open Indexer\n");

        // Handler registrations using indexer.onEvent + GADT event identity
        for event in &self.imported_events {
            content.push('\n');
            content.push_str(&format!(
                "indexer.onEvent({{event: {}({})}}, async ({{event, context}}) => {{\n",
                self.name.capitalized, event.name
            ));
            content.push_str(&format!(
                "  let entity: Entities.{}_{}.t = {{\n",
                self.name.capitalized, event.name
            ));
            content.push_str(&format!("    id: {},\n", event.entity_id_from_event_code));

            // Add params. Leaf params pass through directly; addresses get
            // a `->Address.toString` conversion. Tuple params (including
            // `tuple[]`) flow through as JSON entity columns — the event
            // value is already a structured JS object at runtime, so we only
            // need a magic cast so ReScript's type system accepts assigning
            // it to the `JSON.t` entity column.
            for param in &event.params {
                let base = format!("event.params.{}", param.event_key.uncapitalized);
                content.push_str(&format!("    {}: {}", param.entity_key.uncapitalized, base));

                if param.is_eth_address {
                    content.push_str("\n      ->Address.toString");
                } else if param.is_json_entity_field {
                    content.push_str("->(Utils.magic: _ => JSON.t)");
                }

                content.push_str(",\n");
            }

            content.push_str("  }\n\n");
            content.push_str(&format!(
                "  context.\\\"{}_{}\".set(entity)\n",
                self.name.capitalized, event.name
            ));
            content.push_str("})\n");
        }

        content
    }
    /// Generates TypeScript test file content for this contract
    pub fn generate_typescript_test_content(&self, is_fuel: bool, chain_id: u64) -> String {
        let first_event = match self.imported_events.first() {
            Some(event) => event,
            None => return String::new(),
        };

        let contract_name = &self.name.capitalized;
        let event_name = &first_event.name;
        let entity_name = format!("{}_{}", contract_name, event_name);
        let entity_id = format!("{}_0_0", chain_id);

        let has_address_param = first_event.params.iter().any(|p| p.is_eth_address);

        let mut content = String::new();

        // Imports
        content.push_str("import { describe, it } from \"vitest\";\n");
        if is_fuel {
            content.push_str("import { createTestIndexer } from \"generated\";\n");
        } else {
            content.push_str(&format!(
                "import {{ createTestIndexer, type {} }} from \"generated\";\n",
                entity_name
            ));
            if has_address_param {
                content.push_str("import { TestHelpers } from \"envio\";\n");
            }
        }

        // Mock event test — skip for Fuel because Fuel event params can't be
        // extracted from the ABI yet, so the generated mock may be incomplete.
        if !is_fuel {
            content.push_str(&format!(
                "\ndescribe(\"{} contract {} event tests\", () => {{\n",
                contract_name, event_name
            ));
            content.push_str(&format!(
                "  it(\"{}_{} is created correctly\", async (t) => {{\n",
                contract_name, event_name
            ));
            content.push_str("    const indexer = createTestIndexer();\n");

            // Mock event
            content.push_str(&format!(
                "\n    // Creating mock for {} contract {} event\n",
                contract_name, event_name
            ));
            content.push_str("    const event = {\n");
            content.push_str(&format!(
                "      contract: \"{}\" as const,\n",
                contract_name
            ));
            content.push_str(&format!("      event: \"{}\" as const,\n", event_name));
            if !first_event.params.is_empty() {
                content.push_str("      params: {\n");
                for param in &first_event.params {
                    content.push_str(&format!(
                        "        {}: {},\n",
                        param.js_name, param.default_value_typescript
                    ));
                }
                content.push_str("      },\n");
            }
            content.push_str("    };\n");

            // Process
            content.push_str("\n    await indexer.process({\n");
            content.push_str("      chains: {\n");
            content.push_str(&format!("        {}: {{\n", chain_id));
            content.push_str("          simulate: [event],\n");
            content.push_str("        },\n");
            content.push_str("      },\n");
            content.push_str("    });\n");

            // Get actual entity
            content.push_str("\n    // Getting the actual entity from the test indexer\n");
            content.push_str(&format!(
                "    let actual{}{} = await indexer.{}_{}.getOrThrow(\"{}\");\n",
                contract_name, event_name, contract_name, event_name, entity_id
            ));

            // Expected entity
            content.push_str("\n    // Creating the expected entity\n");
            content.push_str(&format!(
                "    const expected{}{}: {}_{} = {{\n",
                contract_name, event_name, contract_name, event_name
            ));
            content.push_str(&format!("      id: \"{}\",\n", entity_id));
            for param in &first_event.params {
                content.push_str(&format!(
                    "      {}: event.params.{},\n",
                    param.entity_key.uncapitalized, param.js_name
                ));
            }
            content.push_str("    };\n");

            // Assert
            content.push_str(
                "    // Asserting that the entity in the mock database is the same as the expected entity\n",
            );
            content.push_str(&format!(
                "    t.expect(actual{}{}, \"Actual {}{} should be the same as the expected {}{}\").toEqual(expected{}{});\n",
                contract_name, event_name,
                contract_name, event_name,
                contract_name, event_name,
                contract_name, event_name,
            ));

            content.push_str("  });\n");
            content.push_str("});\n");
        }

        // Auto-exit smoke test: fetches first block with events from HyperSync and exits
        content.push_str("\ndescribe(\"Indexer smoke test\", () => {\n");
        content.push_str(&format!(
            "  it(\"processes the first block with events on chain {}\", async (t) => {{\n",
            chain_id
        ));
        content.push_str("    const indexer = createTestIndexer();\n\n");
        content.push_str(&format!(
            "    const result = await indexer.process({{ chains: {{ {}: {{}} }} }});\n\n",
            chain_id
        ));
        content.push_str(
            "    t.expect(result.changes.length, \"Should have at least one change\").toBeGreaterThan(0);\n",
        );
        content.push_str("    const firstChange = result.changes[0]!;\n");
        content.push_str(&format!(
            "    t.expect(firstChange.chainId).toBe({});\n",
            chain_id
        ));
        content.push_str("    t.expect(firstChange.eventsProcessed).toBeGreaterThan(0);\n");
        content.push_str("  }, 60_000);\n");
        content.push_str("});\n");

        content
    }

    /// Generates ReScript test file content for this contract
    pub fn generate_rescript_test_content(&self, is_fuel: bool, chain_id: u64) -> String {
        let first_event = match self.imported_events.first() {
            Some(event) => event,
            None => return String::new(),
        };

        let contract_name = &self.name.capitalized;
        let event_name = &first_event.name;
        let entity_name = format!("{}_{}", contract_name, event_name);
        let entity_id = format!("{}_0_0", chain_id);

        let mut content = String::new();

        content.push_str("open Vitest\n");
        content.push_str("open Indexer\n");

        // Mock event test — skip for Fuel because Fuel event params can't be
        // extracted from the ABI yet, so the generated mock may be incomplete.
        if !is_fuel {
            content.push_str(&format!(
                "\ndescribe(\"{} contract {} event tests\", () => {{\n",
                contract_name, event_name
            ));
            content.push_str(&format!(
                "  Async.it(\"{} handler creates {} entity\", async t => {{\n",
                event_name, entity_name
            ));
            content.push_str("    let indexer = createTestIndexer()\n");

            // Process with simulate item using makeSimulateItem
            content.push_str("\n    let _ = await indexer.process({\n");
            content.push_str("      chains: {\n");
            content.push_str(&format!("        \\\"{}\": {{\n", chain_id));

            // Generate makeSimulateItem call using GADT-based eventIdentity
            if first_event.params.is_empty() {
                content.push_str(&format!(
                    "          simulate: [makeSimulateItem(OnEvent({{event: {}({})}}))],\n",
                    contract_name, event_name
                ));
            } else {
                content.push_str(&format!(
                    "          simulate: [\n\
                     \x20           makeSimulateItem(\n\
                     \x20             OnEvent({{\n\
                     \x20               event: {}({}),\n\
                     \x20               params: {{\n",
                    contract_name, event_name
                ));
                for param in &first_event.params {
                    content.push_str(&format!(
                        "                  {}: {},\n",
                        param.res_name, param.default_value_rescript
                    ));
                }
                content.push_str("              },\n");
                content.push_str("            }),\n");
                content.push_str("          ),\n");
                content.push_str("          ],\n");
            }

            content.push_str("        },\n");
            content.push_str("      },\n");
            content.push_str("    })\n");

            // Get actual entity and assert against expected
            content.push_str(&format!(
                "\n    let actual{contract_name}{event_name} = await indexer.\\\"{entity_name}\".getOrThrow(\"{entity_id}\")\n",
            ));

            content.push_str(&format!(
                "\n    let expected{contract_name}{event_name}: Entities.{entity_name}.t = {{\n\
                 \x20     id: \"{entity_id}\",\n",
            ));
            for param in &first_event.params {
                let value = if param.is_eth_address {
                    format!("{}->Address.toString", param.default_value_rescript)
                } else if param.is_json_entity_field {
                    // Tuple defaults are structured records (matching the
                    // runtime event shape); cast to `JSON.t` for the entity
                    // column.
                    format!(
                        "{}->(Utils.magic: _ => JSON.t)",
                        param.default_value_rescript
                    )
                } else {
                    param.default_value_rescript.clone()
                };
                content.push_str(&format!(
                    "      {}: {},\n",
                    param.entity_key.uncapitalized, value
                ));
            }
            content.push_str("    }\n");

            // Assert
            content.push_str(&format!(
                "\n    t.expect(\n\
                 \x20     actual{contract_name}{event_name},\n\
                 \x20     ~message=\"Actual {entity_name} should be the same as the expected {entity_name}\",\n\
                 \x20   ).toEqual(expected{contract_name}{event_name})\n",
            ));

            content.push_str("  })\n");
            content.push_str("})\n");
        }

        // Auto-exit smoke test: fetches first block with events from HyperSync and exits
        let chain_config_type = if is_fuel {
            "fuelChainConfig"
        } else {
            "evmChainConfig"
        };
        content.push_str("\ndescribe(\"Indexer smoke test\", () => {\n");
        content.push_str(&format!(
            "  Async.it(\"processes the first block with events on chain {}\", async t => {{\n",
            chain_id
        ));
        content.push_str("    let indexer = createTestIndexer()\n\n");
        content.push_str(&format!(
            "    let result = await indexer.process({{\n      chains: {{\n        \\\"{}\": ({{}} : TestIndexer.{}),\n      }},\n    }})\n\n",
            chain_id, chain_config_type
        ));
        content.push_str("    t.expect(\n");
        content.push_str("      result.changes->Array.length,\n");
        content.push_str("      ~message=\"Should have at least one change\",\n");
        content.push_str("    ).toBeGreaterThan(0)\n");
        content.push_str("  }, ~timeout=60_000)\n");
        content.push_str("})\n");

        content
    }
}

#[derive(Serialize)]
pub struct Event {
    name: String,
    entity_id_from_event_code: String,
    create_mock_code: String,
    params: Vec<Param>,
}

impl Event {
    /// Returns the code to get the entity id from an event
    pub fn get_entity_id_code(is_fuel: bool, language: &Language) -> String {
        let int_as_string = |int_var_name| match language {
            Language::ReScript => format!("{int_var_name}->Belt.Int.toString"),
            Language::TypeScript => int_var_name,
        };
        let int_event_prop_as_string =
            |event_prop: &str| int_as_string(format!("event.{event_prop}"));
        let chain_id_str = match language {
            Language::ReScript => int_as_string("(event.chainId :> int)".to_string()),
            Language::TypeScript => "event.chainId".to_string(),
        };

        let block_number_field = match is_fuel {
            true => "block.height",
            false => "block.number",
        };
        let block_number_str = int_event_prop_as_string(block_number_field);

        let log_index_str = int_event_prop_as_string("logIndex");

        format!("`${{{chain_id_str}}}_${{{block_number_str}}}_${{{log_index_str}}}`",)
    }

    fn get_create_mock_code(
        event: &system_config::Event,
        contract: &system_config::Contract,
        is_fuel: bool,
        language: &Language,
    ) -> String {
        let event_module = format!("{}.{}", contract.name.capitalize(), event.name.capitalize());
        match is_fuel {
            true => {
                let data_code = match language {
                    Language::ReScript => "%raw(`{}`)",
                    Language::TypeScript => "{}",
                };
                format!(
                    "{event_module}.mock({{data: {data_code} /* It mocks event fields with \
                   default values, so you only need to provide data */}})"
                )
            } // FIXME: Generate default data
            false => format!(
                "{event_module}.createMockEvent({{/* It mocks event fields with default values. \
               You can overwrite them if you need */}})"
            ),
        }
    }

    fn from_config_event(
        event: &system_config::Event,
        contract: &system_config::Contract,
        is_fuel: bool,
        language: &Language,
    ) -> Result<Option<Self>> {
        let empty_params = vec![];
        let params = match &event.kind {
            EventKind::Params(params) => params,
            EventKind::Fuel(_) => &empty_params,
        };

        // Try to convert each parameter, collecting results and errors
        let mut converted_params = Vec::new();
        let mut has_unsupported_types = false;

        for flattened_param in flatten_event_inputs(params.clone()) {
            match Param::from_event_param(flattened_param.clone()) {
                Ok(param) => converted_params.push(param),
                Err(e) => {
                    // Log warning about the unsupported parameter type
                    eprintln!(
                        "Warning: Skipping event '{}' in contract '{}': parameter '{}' has unsupported type - {}",
                        event.name,
                        contract.name,
                        flattened_param.event_param.name,
                        e
                    );
                    has_unsupported_types = true;
                    break; // Skip this entire event
                }
            }
        }

        // If any parameter has unsupported types, skip the entire event
        if has_unsupported_types {
            return Ok(None);
        }

        Ok(Some(Event {
            name: event.name.to_string(),
            entity_id_from_event_code: Event::get_entity_id_code(is_fuel, language),
            create_mock_code: Event::get_create_mock_code(event, contract, is_fuel, language),
            params: converted_params,
        }))
    }
}

///Param is used both in the context of an entity and an event for the generating
///schema and handlers.
#[derive(Serialize, Clone)]
pub struct Param {
    res_name: String,
    js_name: String,
    ///Entity column name. Matches the param name, except for `id` which is
    ///renamed to `event_id` to avoid clashing with the entity primary key.
    entity_key: CapitalizedOptions,
    ///Runtime event-object key. Same as the param name.
    event_key: CapitalizedOptions,
    graphql_type: FieldType,
    is_eth_address: bool,
    ///True when the param is a tuple (struct), `tuple[]`, or `tuple[N]`.
    ///These render as JSON entity columns; the ReScript handler casts the
    ///structured value through `Utils.magic` so the type checker accepts it
    ///against the `JSON.t` entity field. TypeScript's `unknown` accepts any
    ///value so no cast is needed.
    is_json_entity_field: bool,
    default_value_rescript: String,
    default_value_typescript: String,
}

impl Param {
    fn from_event_param(flattened_event_param: FlattenedEventParam) -> Result<Self> {
        use crate::config_parsing::abi_compat::AbiType;

        let js_name = flattened_event_param.event_param.name.to_string();
        let res_name = RecordField::to_valid_rescript_name(&js_name);
        let eth_param: crate::config_parsing::event_parsing::EvmEventParam =
            (&flattened_event_param.event_param).into();
        let type_ident = abi_to_rescript_type(&eth_param);
        let default_value_rescript = type_ident.get_default_value_rescript();
        let default_value_typescript = type_ident.get_default_value_non_rescript();

        // Detect tuple / array-of-tuple params. These get flattened to a
        // single JSON entity column instead of per-field expansion, so the
        // contract-import path handles every ABI shape uniformly.
        let is_json_entity_field = match &flattened_event_param.event_param.kind {
            AbiType::Tuple(_) => true,
            AbiType::Array(inner) | AbiType::FixedArray(inner, _) => {
                matches!(inner.as_ref(), AbiType::Tuple(_))
            }
            _ => false,
        };

        Ok(Param {
            res_name,
            js_name,
            entity_key: flattened_event_param.get_entity_key(),
            event_key: flattened_event_param.get_event_param_key(),
            graphql_type: FieldType::from_dyn_sol_type(
                &flattened_event_param.event_param.kind.to_dyn_sol_type(),
            )
            .context(format!(
                "Converting eth event param '{}' to gql scalar",
                flattened_event_param.event_param.name
            ))?,
            is_eth_address: matches!(flattened_event_param.event_param.kind, AbiType::Address),
            is_json_entity_field,
            default_value_rescript,
            default_value_typescript,
        })
    }
}

impl From<Param> for Field {
    fn from(val: Param) -> Self {
        Field {
            name: val.entity_key.original,
            field_type: val.graphql_type,
        }
    }
}

impl AutoSchemaHandlerTemplate {
    pub fn try_from(
        config: SystemConfig,
        language: &Language,
        envio_api_token: Option<String>,
    ) -> Result<Self> {
        let imported_contracts = config
            .get_contracts()
            .iter()
            .map(|contract| {
                Contract::from_config_contract(
                    contract,
                    config.get_ecosystem() == Ecosystem::Fuel,
                    language,
                )
            })
            .collect::<Result<_>>()?;
        let first_chain_id = config.get_chains().first().map(|c| c.id).unwrap_or(1);
        Ok(AutoSchemaHandlerTemplate {
            imported_contracts,
            envio_api_token,
            first_chain_id,
        })
    }

    /// Generates individual handler files for each contract in src/handlers/
    pub fn generate_handler_files(
        &self,
        lang: &Language,
        project_root: &Path,
        is_fuel: bool,
    ) -> Result<()> {
        use std::fs;

        // Create src/handlers directory
        let handlers_dir = project_root.join("src").join("handlers");
        fs::create_dir_all(&handlers_dir).context(format!(
            "Failed to create handlers directory at {:?}",
            handlers_dir
        ))?;

        // Generate a handler file for each contract
        for contract in &self.imported_contracts {
            let (file_extension, content) = match lang {
                Language::TypeScript => {
                    ("ts", contract.generate_typescript_handler_content(is_fuel))
                }
                Language::ReScript => ("res", contract.generate_rescript_handler_content(is_fuel)),
            };

            let file_name = format!("{}.{}", contract.name.capitalized, file_extension);
            let file_path = handlers_dir.join(&file_name);

            fs::write(&file_path, content)
                .context(format!("Failed to write handler file at {:?}", file_path))?;
        }

        Ok(())
    }

    /// Generates test files for the first contract in src/
    fn generate_test_files(
        &self,
        lang: &Language,
        project_root: &Path,
        is_fuel: bool,
    ) -> Result<()> {
        use std::fs;

        let first_contract = match self.imported_contracts.first() {
            Some(c) => c,
            None => return Ok(()),
        };

        let src_dir = project_root.join("src");
        fs::create_dir_all(&src_dir)
            .context(format!("Failed to create src directory at {:?}", src_dir))?;

        let (file_name, content) = match lang {
            Language::TypeScript => (
                "indexer.test.ts",
                first_contract.generate_typescript_test_content(is_fuel, self.first_chain_id),
            ),
            Language::ReScript => (
                "Indexer_test.res",
                first_contract.generate_rescript_test_content(is_fuel, self.first_chain_id),
            ),
        };

        let file_path = src_dir.join(file_name);
        fs::write(&file_path, content)
            .context(format!("Failed to write test file at {:?}", file_path))?;

        Ok(())
    }

    pub fn generate_contract_import_templates(
        &self,
        lang: &Language,
        project_root: &Path,
        is_fuel: bool,
    ) -> Result<()> {
        let template_dirs = TemplateDirs::new();

        let shared_dir = template_dirs
            .get_contract_import_shared_dir()
            .context("Failed getting shared contract import templates")?;

        // Copy shared static content into the project root (not the generated folder)
        template_dirs
            .get_shared_static_dir()?
            .extract(project_root)
            .context("Failed extracting shared static files")?;

        // Generate per-contract handler files in src/handlers/
        self.generate_handler_files(lang, project_root, is_fuel)
            .context("Failed generating handler files")?;

        // Generate test file for the first contract
        self.generate_test_files(lang, project_root, is_fuel)
            .context("Failed generating test files")?;

        // Generate shared templates (schema.graphql, .env)
        let hbs_shared = HandleBarsDirGenerator::new(&shared_dir, &self, project_root);
        hbs_shared
            .generate_hbs_templates()
            .context("Failed generating shared contract import templates")?;

        Ok(())
    }

    pub fn generate_subgraph_migration_templates(
        &self,
        lang: &Language,
        project_root: &Path,
    ) -> Result<()> {
        let template_dirs = TemplateDirs::new();

        let lang_dir = template_dirs
            .get_subgraph_migration_lang_dir(lang)
            .context(format!(
                "Failed getting {} subgraph migration templates",
                lang
            ))?;

        let hbs = HandleBarsDirGenerator::new(&lang_dir, &self, project_root);

        hbs.generate_hbs_templates().context(format!(
            "Failed generating {} subgraph migration templates",
            lang
        ))?;

        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::config_parsing::abi_compat::{AbiTupleField, AbiType, EventParam};
    use pretty_assertions::assert_eq;

    fn unnamed(kind: AbiType) -> AbiTupleField {
        AbiTupleField { name: None, kind }
    }

    fn named(name: &str, kind: AbiType) -> AbiTupleField {
        AbiTupleField {
            name: Some(name.to_string()),
            kind,
        }
    }

    #[test]
    fn flatten_event_preserves_params_one_to_one() {
        // Tuples no longer get broken apart into separate columns; they ride
        // along as a single param (the contract-import entity column is JSON).
        // The only responsibility of `flatten_event_inputs` now is to pair
        // each input with its positional index.
        let event_inputs = vec![
            EventParam {
                // Nameless param should compute to "_0".
                name: "".to_string(),
                kind: AbiType::Address,
                indexed: false,
            },
            EventParam {
                name: "myTupleParam".to_string(),
                kind: AbiType::Tuple(vec![unnamed(AbiType::Uint(256)), unnamed(AbiType::Bool)]),
                indexed: false,
            },
            EventParam {
                name: "tranches".to_string(),
                kind: AbiType::Array(Box::new(AbiType::Tuple(vec![
                    named("amount", AbiType::Uint(128)),
                    named("timestamp", AbiType::Uint(40)),
                ]))),
                indexed: false,
            },
            EventParam {
                // `id` should be renamed to `event_id` for the entity column.
                name: "id".to_string(),
                kind: AbiType::String,
                indexed: false,
            },
        ];

        let expected_flat_inputs = vec![
            FlattenedEventParam::new("", AbiType::Address, false, 0),
            FlattenedEventParam::new(
                "myTupleParam",
                AbiType::Tuple(vec![unnamed(AbiType::Uint(256)), unnamed(AbiType::Bool)]),
                false,
                1,
            ),
            FlattenedEventParam::new(
                "tranches",
                AbiType::Array(Box::new(AbiType::Tuple(vec![
                    named("amount", AbiType::Uint(128)),
                    named("timestamp", AbiType::Uint(40)),
                ]))),
                false,
                2,
            ),
            FlattenedEventParam::new("id", AbiType::String, false, 3),
        ];
        let actual_flat_inputs = flatten_event_inputs(event_inputs);
        assert_eq!(expected_flat_inputs, actual_flat_inputs);

        let expected_entity_keys: Vec<_> = vec!["_0", "myTupleParam", "tranches", "event_id"]
            .into_iter()
            .map(|s| s.to_string().to_capitalized_options())
            .collect();
        let actual_entity_keys: Vec<_> = actual_flat_inputs
            .iter()
            .map(|f| f.get_entity_key())
            .collect();
        assert_eq!(expected_entity_keys, actual_entity_keys);

        let expected_event_keys: Vec<_> = vec!["_0", "myTupleParam", "tranches", "id"]
            .into_iter()
            .map(|s| s.to_string().to_capitalized_options())
            .collect();
        let actual_event_keys: Vec<_> = actual_flat_inputs
            .iter()
            .map(|f| f.get_event_param_key())
            .collect();
        assert_eq!(expected_event_keys, actual_event_keys);
    }

    fn get_test_template_helper(
        configs_file_name: &str,
        language: &Language,
    ) -> AutoSchemaHandlerTemplate {
        use crate::{
            config_parsing::system_config::SystemConfig, project_paths::ParsedProjectPaths,
        };

        let project_root = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let config = format!("configs/{}", configs_file_name);
        let project_paths = ParsedProjectPaths::new(&project_root, &config).expect("Parsed paths");

        let config = SystemConfig::parse_from_project_files(&project_paths)
            .expect("Deserialized yml config should be parseable");

        AutoSchemaHandlerTemplate::try_from(config, language, None)
            .expect("should be able to create template")
    }

    #[test]
    fn typescript_test_file_for_evm() {
        let template = get_test_template_helper("config1.yaml", &Language::TypeScript);
        let content = template.imported_contracts[0]
            .generate_typescript_test_content(false, template.first_chain_id);
        insta::assert_snapshot!(content);
    }

    #[test]
    fn rescript_test_file_for_evm() {
        let template = get_test_template_helper("config1.yaml", &Language::ReScript);
        let content = template.imported_contracts[0]
            .generate_rescript_test_content(false, template.first_chain_id);
        insta::assert_snapshot!(content);
    }

    #[test]
    fn typescript_test_file_for_fuel() {
        let template = get_test_template_helper("fuel-config.yaml", &Language::TypeScript);
        let content = template.imported_contracts[0]
            .generate_typescript_test_content(true, template.first_chain_id);
        insta::assert_snapshot!(content);
    }

    #[test]
    fn rescript_test_file_for_fuel() {
        let template = get_test_template_helper("fuel-config.yaml", &Language::ReScript);
        let content = template.imported_contracts[0]
            .generate_rescript_test_content(true, template.first_chain_id);
        insta::assert_snapshot!(content);
    }

    #[test]
    fn test_get_entity_id_code() {
        const IS_FUEL: bool = true;
        assert_eq!(
            Event::get_entity_id_code(!IS_FUEL, &Language::ReScript),
            "`${(event.chainId :> int)->Belt.Int.toString}_${event.block.number->Belt.Int.\
           toString}_${event.logIndex->Belt.Int.toString}`"
                .to_string()
        );

        assert_eq!(
            Event::get_entity_id_code(IS_FUEL, &Language::TypeScript),
            "`${event.chainId}_${event.block.height}_${event.logIndex}`".to_string()
        );
    }

    // End-to-end contract-import snapshots driven by the real Sablier V2
    // LockupTranched ABI. `CreateLockupTranchedStream` has a mix of tuple
    // shapes (named struct, nested struct, `tuple[]`) that previously bailed
    // out of contract-import entirely. Each tuple param now lands as a JSON
    // entity column; the ReScript handler adds a `Utils.magic` cast to
    // satisfy the `JSON.t` column type.

    #[test]
    fn typescript_handler_for_tuple_events() {
        let template = get_test_template_helper("tuple-events-config.yaml", &Language::TypeScript);
        let content = template.imported_contracts[0].generate_typescript_handler_content(false);
        insta::assert_snapshot!(content);
    }

    #[test]
    fn rescript_handler_for_tuple_events() {
        let template = get_test_template_helper("tuple-events-config.yaml", &Language::ReScript);
        let content = template.imported_contracts[0].generate_rescript_handler_content(false);
        insta::assert_snapshot!(content);
    }

    #[test]
    fn typescript_test_file_for_tuple_events() {
        let template = get_test_template_helper("tuple-events-config.yaml", &Language::TypeScript);
        let content = template.imported_contracts[0]
            .generate_typescript_test_content(false, template.first_chain_id);
        insta::assert_snapshot!(content);
    }

    #[test]
    fn rescript_test_file_for_tuple_events() {
        let template = get_test_template_helper("tuple-events-config.yaml", &Language::ReScript);
        let content = template.imported_contracts[0]
            .generate_rescript_test_content(false, template.first_chain_id);
        insta::assert_snapshot!(content);
    }
}
