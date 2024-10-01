contract;

use std::{
    asset::{
        burn,
        mint,
        mint_to,
        transfer,
    },
    bytes::Bytes,
    call_frames::{
        msg_asset_id,
    },
    constants::ZERO_B256,
    context::msg_amount,
};

abi LiquidityPool {
    #[payable]
    fn deposit(recipient: Identity);
    #[payable]
    fn withdraw(recipient: Identity);
}

const BASE_TOKEN: AssetId = AssetId::from(0xf8f8b6283d7fa5b672b530cbb84fcccb4ff8dc40f8176ef4544ddb1f1952ad07);

// From https://rust.fuel.network/v0.66.5/cookbook/deposit-and-withdraw.html
impl LiquidityPool for Contract {
    #[payable]
    fn deposit(recipient: Identity) {
        assert(BASE_TOKEN == msg_asset_id());
        assert(0 < msg_amount());

        // Mint two times the amount.
        let amount_to_mint = msg_amount() * 2;

        // Mint some LP token based upon the amount of the base token.
        mint_to(recipient, ZERO_B256, amount_to_mint);
    }

    #[payable]
    fn withdraw(recipient: Identity) {
        let token_amount = msg_amount();
        assert(0 < token_amount);
        // Ideally should assert asset_id

        // Amount to withdraw.
        let amount_to_transfer = token_amount / 2;

        // Transfer everything back to recipient address.
        // Besides one token, which is sent to the greeter contract,
        // to test transfer receipt sent to a contract.
        transfer(recipient, BASE_TOKEN, amount_to_transfer - 1);
        transfer(
            Identity::ContractId(ContractId::from(0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b)),
            BASE_TOKEN,
            1,
        );

        burn(ZERO_B256, token_amount);
    }
}

abi AllEvents {
    fn log();
}

struct StatusFailure {
    reason: u32,
}

enum Status {
    Pending: (),
    Completed: u32,
    Failed: StatusFailure,
}

struct SimpleStruct {
    f1: u32,
}

struct SimpleStructWithOptionalField {
    f1: u32,
    f2: Option<u32>,
}

// Not supported at the time of the contract creation
// struct RecursiveStruct {
//     f1: u32,
//     f2: Option<RecursiveStruct>,
// }


impl AllEvents for Contract {
    fn log() {
        let data: unit = ();
        log(data);

        let data: bool = true;
        log(data);

        let data: bool = false;
        log(data);

        let data: u8 = 3;
        log(data);

        let data: u16 = 4;
        log(data);

        let data: u32 = 5;
        log(data);

        let data: u64 = 6;
        log(data);

        let data: u256 = 7;
        log(data);

        let data: str[4] = __to_str_array("abcd");
        log(data);

        // Panics with: Function call failed. Error: String slices can not be decoded from logs. Convert the slice to `str[N]` with `__to_str_array`
        // let data: str = "abcd";
        // log("abcd");

        let data: b256 = 0x0000000000000000000000000000000000000000000000000000000000000001;
        log(data);

        let data: (u64, bool) = (42, true);
        log(data);

        let data: [u8; 5] = [1, 2, 3, 4, 5];
        log(data);

        let data: Result<u32, bool> = Ok(12);
        log(data);

        let data: Result<u32, bool> = Err(false);
        log(data);

        let data: Option<u32> = None;
        log(data);

        let data: Option<u32> = Some(12);
        log(data);

        let data: Option<Option<u32>> = None;
        log(data);

        let data: Option<Option<u32>> = Some(None);
        log(data);

        let data: Option<Option<u32>> = Some(Some(12));
        log(data);

        let data: SimpleStruct = SimpleStruct { f1: 11 };
        log(data);

        let data: SimpleStructWithOptionalField = SimpleStructWithOptionalField {
            f1: 11,
            f2: None,
        };
        log(data);

        let data: SimpleStructWithOptionalField = SimpleStructWithOptionalField {
            f1: 11,
            f2: Some(32),
        };
        log(data);

        let data: Status = Status::Pending;
        log(data);

        let data: Status = Status::Completed(12);
        log(data);

        let data: Status = Status::Failed(StatusFailure { reason: 1 });
        log(data);

        let mut vec: Vec<u64> = Vec::new();
        vec.push(69);
        vec.push(23);
        log(vec);

        let mut bytes = Bytes::new();
        bytes.push(40u8);
        log(bytes)
    }
}
