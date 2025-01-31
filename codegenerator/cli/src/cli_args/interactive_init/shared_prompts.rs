use std::{fmt::Display, future::Future};

use super::{
    inquire_helpers::FilePathCompleter,
    validation::{
        contains_no_whitespace_validator, first_char_is_alphabet_validator,
        is_only_alpha_numeric_characters_validator, UniqueValueValidator,
    },
};

use anyhow::{Context, Result};
use async_recursion::async_recursion;
use inquire::{validator::Validation, CustomType, MultiSelect, Select, Text};

use std::str::FromStr;
use strum::{EnumIter, IntoEnumIterator};

pub fn prompt_template<T: Display>(options: Vec<T>) -> Result<T> {
    Select::new("Which template would you like to use?", options)
        .prompt()
        .context("Prompting user for template selection")
}

pub struct SelectItem<T> {
    pub item: T,
    pub display: String,
    pub preselect: bool,
}

impl<T> Display for SelectItem<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.display)
    }
}

///Takes a vec of Events and sets up a multi selecet prompt
///with all selected by default. Whatever is selected in the prompt
///is returned
pub fn prompt_events_selection<T>(events: Vec<SelectItem<T>>) -> Result<Vec<T>> {
    //Collect all the indexes of the vector in another vector which will be used
    //to preselect all events
    let all_indexes_of_events = events
        .iter()
        .enumerate()
        .filter_map(|(i, event)| if event.preselect { Some(i) } else { None })
        .collect::<Vec<usize>>();

    //Prompt for selection with all events selected by default
    let selected_wrapped_events = MultiSelect::new("Which events would you like to index?", events)
        .with_default(&all_indexes_of_events)
        .prompt()?;

    //Unwrap the selected events and return
    let selected_events = selected_wrapped_events
        .into_iter()
        .map(|w_event| w_event.item)
        .collect();

    Ok(selected_events)
}

pub fn prompt_abi_file_path(
    abi_validator: fn(abi_file_path: &str) -> Validation,
) -> Result<String> {
    Text::new("What is the path to your json abi file?")
        //Auto completes path for user with tab/selection
        .with_autocomplete(FilePathCompleter::default())
        //Tries to parse the abi to ensure its valid and doesn't
        //crash the prompt if not. Simply asks for a valid abi
        .with_validator(move |path: &str| Ok(abi_validator(path)))
        .prompt()
        .context("Failed during prompt for abi file path")
}

pub fn prompt_contract_name() -> Result<String> {
    Text::new("What is the name of this contract?")
        .with_validator(contains_no_whitespace_validator)
        .with_validator(is_only_alpha_numeric_characters_validator)
        .with_validator(first_char_is_alphabet_validator)
        .prompt()
        .context("Failed during contract name prompt")
}

pub fn prompt_contract_address<T: Clone + FromStr + Display + PartialEq + 'static>(
    selected: Option<&Vec<T>>,
) -> Result<T> {
    let mut prompter = CustomType::<T>::new("What is the address of the contract?")
        .with_help_message("Use the proxy address if your abi is a proxy implementation")
        .with_error_message(
            "Please input a valid contract address (should be a hexadecimal starting with (0x))",
        );
    if let Some(selected) = selected {
        prompter = prompter.with_validator(UniqueValueValidator::new(selected.clone()))
    }
    prompter
        .prompt()
        .context("Failed during contract address prompt")
}

///Represents the choice a user makes for adding values to
///their auto config selection
#[derive(strum_macros::Display, EnumIter, Default, PartialEq)]
enum AddNewContractOption {
    #[default]
    #[strum(serialize = "I'm finished")]
    Finished,
    #[strum(serialize = "Add a new address for same contract on same network")]
    AddAddress,
    #[strum(serialize = "Add a new network for same contract")]
    AddNetwork,
    #[strum(serialize = "Add a new contract (with a different ABI)")]
    AddContract,
}

fn prompt_add_new_contract_option(
    contract_name: &String,
    network: &String,
    can_add_network: bool,
) -> Result<AddNewContractOption> {
    let mut options = AddNewContractOption::iter().collect::<Vec<_>>();
    if !can_add_network {
        options = options
            .into_iter()
            .filter(|o| o != &AddNewContractOption::AddNetwork)
            .collect();
    }
    let help_message = format!(
        "Current contract: {}, on network: {}",
        contract_name, network
    );
    Select::new("Would you like to add another contract?", options)
        .with_starting_cursor(0)
        .with_help_message(&help_message)
        .prompt()
        .context("Failed prompting for add contract")
}

pub trait Contract {
    fn get_network_name(&self) -> Result<String>;
    fn get_name(&self) -> String;
    fn add_address(&mut self) -> Result<()>;
    fn add_network(&mut self) -> Result<()>;
}

#[derive(thiserror::Error, Debug)]
enum AutoConfigError {
    #[error("Contract with the name '{}' already selected", .name)]
    ContractNameExists { name: String },
}

#[async_recursion]
pub async fn prompt_to_continue_adding<T, CF, CFut>(
    contracts: &mut Vec<T>,
    mut add_contract: CF,
    can_add_network: bool,
) -> Result<()>
where
    T: Contract + Send,
    CF: FnMut() -> CFut + Send,
    CFut: Future<Output = Result<T>> + Send,
{
    let active_contract = contracts
        .last_mut()
        .context("Failed to get the last selected contract")?;
    let add_new_contract_option = prompt_add_new_contract_option(
        &active_contract.get_name(),
        &active_contract.get_network_name()?,
        can_add_network,
    )?;
    match add_new_contract_option {
        AddNewContractOption::Finished => Ok(()),
        AddNewContractOption::AddAddress => {
            active_contract.add_address()?;
            prompt_to_continue_adding(contracts, add_contract, can_add_network).await
        }
        AddNewContractOption::AddNetwork => {
            active_contract.add_network()?;
            prompt_to_continue_adding(contracts, add_contract, can_add_network).await
        }
        AddNewContractOption::AddContract => {
            let contract = add_contract().await?;
            let contract_name_lower = contract.get_name().to_lowercase();
            let contract_name_exists = contracts
                .iter()
                .find(|c| &c.get_name().to_lowercase() == &contract_name_lower)
                .is_some();

            if contract_name_exists {
                //TODO: Handle more cases gracefully like:
                // - contract + event is exact match, in which case it should just merge networks and
                // addresses
                // - Contract has some matching addresses to another contract but all different events
                // - Contract has some matching events as another contract?
                Err(AutoConfigError::ContractNameExists {
                    name: contract.get_name(),
                })?
            } else {
                contracts.push(contract);
                prompt_to_continue_adding(contracts, add_contract, can_add_network).await
            }
        }
    }
}
