//! Kerrigan Sapling (shield) wallet core with a C ABI for Flutter (dart:ffi).
//!
//! One entry point, `kerrigan_shield_call(method, args_json)`, returns a
//! JSON string `{"ok": <result>}` or `{"err": "<message>"}` that the caller
//! must release with `kerrigan_shield_free`. Panics are caught and reported
//! as errors so they never unwind across the FFI boundary.
//!
//! Kerrigan puts Sapling bundles in a special transaction (nVersion 3,
//! nType 10) with its own signature hash, so this crate reads and writes
//! transactions itself and uses `sapling-crypto` for keys, notes, proofs
//! and signatures.
mod build;
mod keys;
mod network;
mod prover;
mod scan;
mod tree;
mod tx;

#[cfg(test)]
mod tests;

use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use network::Network;

pub(crate) type Error = String;
type CallResult = Result<Value, Error>;

fn parse<T: for<'de> Deserialize<'de>>(args: &str) -> Result<T, Error> {
    serde_json::from_str(args).map_err(|e| format!("invalid arguments: {e}"))
}

fn to_value<T: serde::Serialize>(v: T) -> CallResult {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

#[derive(Deserialize)]
struct SeedArgs {
    seed_hex: String,
    coin_type: u32,
    #[serde(default)]
    account_index: u32,
}

#[derive(Deserialize)]
struct KeyArgs {
    key: String,
}

#[derive(Deserialize)]
struct AddressKeyArgs {
    key: String,
    network: Network,
}

#[derive(Deserialize)]
struct NextAddressArgs {
    extfvk: String,
    diversifier_index: Vec<u8>,
    network: Network,
}

#[derive(Deserialize)]
struct CheckpointArgs {
    network: Network,
}

#[derive(Deserialize)]
struct HandleBlocksArgs {
    tree: String,
    blocks: Vec<scan::Block>,
    extfvk: String,
    network: Network,
    notes: Vec<scan::JSSpendableNote>,
}

#[derive(Deserialize)]
struct TreeArgs {
    tree: String,
}

#[derive(Deserialize)]
struct ProverArgs {
    output_path: String,
    spend_path: String,
}

#[derive(Deserialize)]
struct AddressArgs {
    address: String,
    network: Network,
}

#[derive(Deserialize)]
struct FeeArgs {
    spends: usize,
    outputs: usize,
}

fn dispatch(method: &str, args: &str) -> CallResult {
    match method {
        "version" => Ok(json!(env!("CARGO_PKG_VERSION"))),
        "generate_extsk" => {
            let a: SeedArgs = parse(args)?;
            let seed = hex::decode(&a.seed_hex).map_err(|_| "Seed is not hex")?;
            keys::extsk_from_seed(&seed, a.coin_type, a.account_index).map(Value::from)
        }
        "generate_extfvk" => {
            let a: KeyArgs = parse(args)?;
            keys::extfvk_from_extsk(&a.key).map(Value::from)
        }
        "default_address" => {
            let a: AddressKeyArgs = parse(args)?;
            keys::default_address(&a.key, a.network).and_then(to_value)
        }
        "change_address" => {
            let a: AddressKeyArgs = parse(args)?;
            keys::change_address(&a.key, a.network).map(Value::from)
        }
        "next_address" => {
            let a: NextAddressArgs = parse(args)?;
            keys::next_address(&a.extfvk, &a.diversifier_index, a.network).and_then(to_value)
        }
        "validate_address" => {
            let a: AddressArgs = parse(args)?;
            Ok(json!(keys::is_valid_shield_address(&a.address, a.network)))
        }
        "closest_checkpoint" => {
            // No commitment tree checkpoints yet: Kerrigan's Sapling pool is
            // young, so wallets scan from activation, where the tree is empty.
            let a: CheckpointArgs = parse(args)?;
            let height = a.network.sapling_height().saturating_sub(1);
            Ok(json!({ "height": height, "tree": "000000" }))
        }
        "handle_blocks" => {
            let a: HandleBlocksArgs = parse(args)?;
            scan::handle_blocks(&a.tree, a.blocks, &a.extfvk, a.network, a.notes).and_then(to_value)
        }
        "sapling_root" => {
            let a: TreeArgs = parse(args)?;
            tree::sapling_root(&a.tree).map(Value::from)
        }
        "sapling_fee" => {
            let a: FeeArgs = parse(args)?;
            Ok(json!(build::sapling_fee(a.spends, a.outputs)))
        }
        "load_prover" => {
            let a: ProverArgs = parse(args)?;
            prover::load_from_files(&a.output_path, &a.spend_path).map(|_| json!(true))
        }
        "prover_is_loaded" => Ok(json!(prover::is_loaded())),
        "create_transaction" => {
            let a: build::JSTxOptions = parse(args)?;
            build::create_transaction(a).and_then(to_value)
        }
        _ => Err(format!("unknown method: {method}")),
    }
}

/// Call `method` with JSON `args`. Returns a heap-allocated JSON string
/// that must be released with [`kerrigan_shield_free`].
///
/// # Safety
/// `method` and `args` must be valid NUL-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn kerrigan_shield_call(method: *const c_char, args: *const c_char) -> *mut c_char {
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let method = CStr::from_ptr(method).to_str().map_err(|e| e.to_string())?;
        let args = CStr::from_ptr(args).to_str().map_err(|e| e.to_string())?;
        dispatch(method, args)
    }));
    let response = match outcome {
        Ok(Ok(v)) => json!({ "ok": v }),
        Ok(Err(e)) => json!({ "err": e }),
        Err(panic) => {
            let msg = panic
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".into());
            json!({ "err": format!("panic: {msg}") })
        }
    };
    CString::new(response.to_string()).unwrap_or_default().into_raw()
}

/// Release a string returned by [`kerrigan_shield_call`].
///
/// # Safety
/// `s` must come from `kerrigan_shield_call` and not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn kerrigan_shield_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
