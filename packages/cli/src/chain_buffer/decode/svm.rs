//! Borsh decoding of an instruction under each registration it matched, and
//! the logs each registration selected.

use std::sync::Arc;

use crate::chain_buffer::svm::{decode_path, InstructionView};
use crate::chain_buffer::walk::Item;
use crate::js_value::JsTape;
use crate::svm_hypersync_source::selection::{Instruction, Registration};

/// The logs as a registration selected them: each of `kind` and `message`
/// it chose, absent ones left out.
fn logs_tape(logs: &[(String, String)], columns: &[&str]) -> JsTape {
    let want_kind = columns.contains(&"kind");
    let want_message = columns.contains(&"message");
    let mut tape = JsTape::new();
    tape.arr(logs.len());
    for (kind, message) in logs {
        tape.obj(2);
        tape.key("kind");
        if want_kind {
            tape.str(kind);
        } else {
            tape.undefined();
        }
        tape.key("message");
        if want_message {
            tape.str(message);
        } else {
            tape.undefined();
        }
    }
    tape
}

/// One item per matched registration. An instruction whose declared layout
/// rejects the call's data gives none of its registrations an item.
pub(crate) fn instruction_items(
    call: &InstructionView,
    matched: &[(&Arc<Instruction>, &Arc<Registration>)],
    accepts: impl Fn(&Registration) -> bool,
    items: &mut Vec<Item>,
) {
    let mut decoded: Vec<(*const Instruction, Option<Option<JsTape>>)> = Vec::new();
    let path = decode_path(call.path);
    for (instruction, registration) in matched {
        if !accepts(registration) {
            continue;
        }
        let pointer = Arc::as_ptr(instruction);
        let args = match decoded.iter().find(|(seen, _)| *seen == pointer) {
            Some((_, args)) => args.clone(),
            None => {
                let args = match &instruction.args {
                    None => Some(None),
                    Some(schema) => schema.decode(call.data).map(Some),
                };
                decoded.push((pointer, args.clone()));
                args
            }
        };
        let Some(args) = args else { continue };
        let logs = (!registration.log_columns.is_empty()).then(|| {
            logs_tape(
                call.logs.as_deref().unwrap_or_default(),
                &registration.log_columns,
            )
        });
        items.push(Item::Svm {
            slot: call.slot,
            transaction_index: call.transaction_index,
            path: path.clone(),
            registration: registration.index as u32,
            program_id: call.program_id.to_string(),
            accounts: call.accounts.clone(),
            data: call.data.to_vec(),
            is_inner: call.is_inner,
            args: args.filter(|_| registration.selects_args),
            logs,
        });
    }
}
