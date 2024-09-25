contract;

use std::asset::{burn, mint, transfer};
use std::bytes::Bytes;

abi Token {
    fn transfer_to_address(target: Address, asset_id: AssetId, coins: u64);
    fn transfer_to_contract(recipient: ContractId, asset_id: AssetId, coins: u64);
    fn mint_coins(sub_id: b256, mint_amount: u64);
    fn burn_coins(sub_id: b256, burn_amount: u64);
}

impl Token for Contract {
    fn transfer_to_address(recipient: Address, asset_id: AssetId, amount: u64) {
        transfer(Identity::Address(recipient), asset_id, amount);
    }

    fn transfer_to_contract(target: ContractId, asset_id: AssetId, amount: u64) {
        transfer(Identity::ContractId(target), asset_id, amount);
    }

    fn mint_coins(sub_id: b256, mint_amount: u64) {
        mint(sub_id, mint_amount);
    }

    fn burn_coins(sub_id: b256, burn_amount: u64) {
        burn(sub_id, burn_amount);
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
