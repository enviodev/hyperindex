//! A receipt's params under one registration: LogData decoded with the
//! registration's ABI, the other kinds flattened from their columns.

use crate::chain_buffer::deliver::utf8;
use crate::chain_buffer::selection::fuel::{RegistrationKind, RECEIPT_TRANSFER_OUT};
use crate::chain_buffer::tables::fuel::ReceiptView;
use crate::js_value::JsTape;

/// `None` when the receipt doesn't decode under the registration: LogData
/// its logged type rejects, or a kind whose columns the source left out.
pub(crate) fn params(kind: &RegistrationKind, receipt: &ReceiptView) -> Option<JsTape> {
    match kind {
        RegistrationKind::LogData { decoder, .. } => decoder.decode(receipt.data?),
        RegistrationKind::Mint | RegistrationKind::Burn => {
            Some(supply_params(&utf8(receipt.sub_id?), receipt.val?))
        }
        RegistrationKind::Transfer | RegistrationKind::Call => {
            // A TransferOut carries the wallet recipient in `to_address`.
            let to = if receipt.receipt_type == RECEIPT_TRANSFER_OUT {
                receipt.to_address
            } else {
                receipt.to
            }?;
            Some(transfer_params(
                &utf8(to),
                &utf8(receipt.asset_id?),
                receipt.amount?,
            ))
        }
    }
}

fn supply_params(sub_id: &str, amount: u64) -> JsTape {
    let mut tape = JsTape::new();
    tape.obj(2);
    tape.key("subId");
    tape.str(sub_id);
    tape.key("amount");
    tape.bigint(false, &[amount]);
    tape
}

fn transfer_params(to: &str, asset_id: &str, amount: u64) -> JsTape {
    let mut tape = JsTape::new();
    tape.obj(3);
    tape.key("to");
    tape.str(to);
    tape.key("assetId");
    tape.str(asset_id);
    tape.key("amount");
    tape.bigint(false, &[amount]);
    tape
}
