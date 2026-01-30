
use anyhow::{Context, Result};
use inquire::{MultiSelect, Select, Text};
use crate::cli_args::interactive_init::navigation::PromptResult;

pub fn prompt_select_with_back<T: std::fmt::Display>(
    message: &str,
    options: Vec<T>,
    context_msg: &str,
) -> Result<PromptResult<T>> {
    let context_msg = context_msg.to_string();
    // TODO: Append "Press Esc to go back" to default help message instead of replacing
    // Default: "↑↓ to move, enter to select, type to filter"
    let help_msg = "↑↓ to move, enter to select, type to filter, Esc to go back";
    let result = Select::new(message, options)
        .with_help_message(help_msg)
        .prompt_skippable()
        .context(context_msg)?;
    
    match result {
        Some(value) => Ok(PromptResult::Value(value)),
        None => Ok(PromptResult::Back), // Esc pressed
    }
}

pub fn prompt_text_with_back(
    message: &str,
    default: Option<&str>,
) -> Result<PromptResult<String>> {
    // TODO: Append "Press Esc to go back" to default help message instead of replacing
    // Default: "enter to submit"
    let help_msg = "enter to submit, Esc to go back";
    let mut prompt = Text::new(message)
        .with_help_message(help_msg);
    
    if let Some(default_value) = default {
        prompt = prompt.with_default(default_value);
    }
    
    let result = prompt
        .prompt_skippable()
        .context("Failed to prompt for text input")?;
    
    match result {
        Some(value) => Ok(PromptResult::Value(value)),
        None => Ok(PromptResult::Back), // Esc pressed
    }
}

pub fn prompt_multiselect_with_back<T: std::fmt::Display>(
    message: &str,
    options: Vec<T>,
    default: Option<&[usize]>,
    context_msg: &str,
) -> Result<PromptResult<Vec<T>>> {
    let context_msg = context_msg.to_string();
    let help_msg = "↑↓ to move, space to select one, → to all, ← to none, type to filter, Esc to go back";
    let mut prompt = MultiSelect::new(message, options)
        .with_help_message(help_msg);
    
    if let Some(default_indices) = default {
        prompt = prompt.with_default(default_indices);
    }
    
    let result = prompt
        .prompt_skippable()
        .context(context_msg)?;
    
    match result {
        Some(selected) => Ok(PromptResult::Value(selected)),
        None => Ok(PromptResult::Back), // Esc pressed
    }
}


