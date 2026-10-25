//! Tests through the JSON dispatcher (the same path Dart uses), with
//! vectors from a Kerrigan Core regtest node (v1.3.2):
//! - `regtest_xsk.hex`: `z_exportkey` of the node wallet's Sapling key
//! - `regtest_blocks.json`: the Sapling txs of blocks 201, 202 and 204:
//!   201: transparent → 12.5 KRGN, memo "hello"
//!   202: that note → 2.5 KRGN transparent, 9.99975 change
//!   204: transparent → 3 and 4 KRGN
//!
//! Core's `z_listaddresses` also lists the default address of the key's
//! internal (change) key; the 12.5 and 3 KRGN notes went there.
use crate::dispatch;
use serde_json::{json, Value};

const XSK: &str = include_str!("../testdata/regtest_xsk.hex");
const BLOCKS: &str = include_str!("../testdata/regtest_blocks.json");
/// `z_exportviewingkey` of the key's addresses.
const VIEWING_KEY: &str = "2913cc23cc56faefdc38e2c6310dcf6c61e1af5181413b9ea662c1a6c2d28a4c985d0e196bb78687c5c43a73232ce60f137b17a05260c5e7622ad47e3c5936a793bc3089a4c207f7d97db05ee8a72b14fdac9f088531b1595e0f5f607c94d99fede35eea3b99cbdfe9245b0727ebc8f1bee276e425611140b42daa2e855618fe";
/// Core's first two `z_getnewaddress` answers: the key's default address
/// and the next one.
const NODE_ADDRESSES: [&str; 2] = [
    "kregsapling13ckrgka9mn7nxwxcy6xzzhtp6uw0ttt777qq8kvyvpwwvggeas9af89kxhns7kqkk9asg2uhevq",
    "kregsapling1pkw627ug36avmsq584wq4nd2j5k92wvheruv7gmwujky5k9n3srksg7sk4c7lt68xdntwtc8565",
];
/// Default address of the internal key.
const INTERNAL_DEFAULT: &str = "kregsapling12pl8nuy7rr2ja6adwmtf423pktlzs9wlxtl0klqnnmj9d342zqp2k2n4vwrqst6z7snlz30snj6";
/// Address of the 9.99975 KRGN change note (an internal address Core chose).
const CHANGE_ADDRESS: &str = "kregsapling12s90as2wau3et9rr20k88j8fq04s4clcpljd32t76rra4t8lpya9dwvqlkpg7c7np9tqz0kye0y";

fn call(method: &str, args: Value) -> Value {
    dispatch(method, &args.to_string()).unwrap_or_else(|e| panic!("{method}: {e}"))
}

fn call_err(method: &str, args: Value) -> String {
    dispatch(method, &args.to_string()).expect_err(method)
}

#[test]
fn viewing_key_matches_kerrigan_core() {
    let extfvk = call("generate_extfvk", json!({"key": XSK.trim()}));
    assert_eq!(extfvk, json!(VIEWING_KEY));
}

#[test]
fn addresses_match_kerrigan_core() {
    let def = call("default_address", json!({"key": VIEWING_KEY, "network": "regtest"}));
    assert_eq!(def["address"], NODE_ADDRESSES[0]);
    let next = call(
        "next_address",
        json!({"extfvk": VIEWING_KEY, "diversifier_index": def["diversifier_index"], "network": "regtest"}),
    );
    assert_eq!(next["address"], NODE_ADDRESSES[1]);

    let change = call("change_address", json!({"key": VIEWING_KEY, "network": "regtest"}));
    assert_eq!(change, json!(INTERNAL_DEFAULT));

    for a in [NODE_ADDRESSES[0], NODE_ADDRESSES[1], INTERNAL_DEFAULT, CHANGE_ADDRESS] {
        assert_eq!(call("validate_address", json!({"address": a, "network": "regtest"})), json!(true));
        assert_eq!(call("validate_address", json!({"address": a, "network": "test"})), json!(false));
    }
    // Bech32 (not Bech32m) checksums and other strings are rejected.
    for bad in ["kregsapling1", "yeiahYKSYceWZji4SMJ6sQSTYsyELJxf1T", ""] {
        assert_eq!(call("validate_address", json!({"address": bad, "network": "regtest"})), json!(false));
    }
}

/// Kerrigan Core v1.3.2 regtest wallet restored with `upgradetohd` from
/// "abandon … about" (no passphrase): its first `z_getnewaddress` and
/// `z_exportviewingkey`. The same mnemonic gives the same shield keys.
#[test]
fn seed_keys_match_kerrigan_core() {
    // BIP39 seed of "abandon abandon … about".
    let seed = "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4";
    let xsk = call("generate_extsk", json!({"seed_hex": seed, "coin_type": 1}));
    let fvk = call("generate_extfvk", json!({"key": xsk}));
    assert_eq!(fvk, json!("9f2a5482b353b4a3b7f6b52ec7dc81cc45093ad3c81588a01842fe3bf676f5a1aa837cac9410446c8bf61ee1acf758dd688cdce0394a20e9266f08f1d26e14e7afdd90eddb8f2f3e3e6147557f35476ca0d7176ec3c5b41dc46c22de2d3b40a689852137158a60cc4ea81569760651f2523af019de4b006a63582716bf85aa03"));
    let addr = call("default_address", json!({"key": fvk, "network": "regtest"}));
    assert_eq!(
        addr["address"],
        "kregsapling1j9s20dpe62kr0jhfvnqua3j8wv873ccy7u3l3fuwgvc8l4yy0dqpnaknkp3g0uaj0jynjpyc6ul"
    );
}

#[test]
fn seed_derivation_is_deterministic_and_per_coin() {
    let seed = "00".repeat(64);
    let main = call("generate_extsk", json!({"seed_hex": seed, "coin_type": 99888}));
    assert_eq!(main, call("generate_extsk", json!({"seed_hex": seed, "coin_type": 99888})));
    assert_ne!(main, call("generate_extsk", json!({"seed_hex": seed, "coin_type": 1})));
    assert_eq!(main.as_str().unwrap().len(), 169 * 2);
    let fvk = call("generate_extfvk", json!({"key": main}));
    let addr = call("default_address", json!({"key": fvk, "network": "main"}));
    assert!(addr["address"].as_str().unwrap().starts_with("ks1"));
}

fn scan_all() -> Value {
    let blocks: Value = serde_json::from_str(BLOCKS).unwrap();
    call(
        "handle_blocks",
        json!({"tree": "000000", "blocks": blocks, "extfvk": VIEWING_KEY, "network": "regtest", "notes": []}),
    )
}

#[test]
fn scans_regtest_blocks_like_kerrigan_core() {
    let r = scan_all();
    let wtx = r["wallet_transactions"].as_array().unwrap();
    assert_eq!(wtx.len(), 3);

    // 201: 12.5 KRGN with a memo, to the internal key.
    assert_eq!(wtx[0]["received"].as_array().unwrap().len(), 1);
    assert_eq!(wtx[0]["received"][0]["value"], 1_250_000_000u64);
    assert_eq!(wtx[0]["received"][0]["memo"], "hello");
    assert_eq!(wtx[0]["received"][0]["address"], INTERNAL_DEFAULT);
    assert_eq!(wtx[0]["received"][0]["change"], true);
    assert_eq!(wtx[0]["value_balance"], -1_250_000_000i64);

    // 202: spends it; 2.5 KRGN and the 0.00025 fee left the pool, the
    // change came back internally.
    let spent_nf = &wtx[0]["received"][0]["nullifier"];
    assert!(wtx[1]["nullifiers"].as_array().unwrap().contains(spent_nf));
    assert_eq!(wtx[1]["received"][0]["value"], 999_975_000u64);
    assert_eq!(wtx[1]["received"][0]["change"], true);
    assert_eq!(wtx[1]["received"][0]["address"], CHANGE_ADDRESS);
    assert_eq!(wtx[1]["value_balance"], 250_025_000i64);
    assert_eq!(wtx[1]["txid"], "5dd0355ac2e88a4cedb83e3dd4037d7b9b2c0b3046eef9f7435862ea0dad2cf2");

    // 204: 3 KRGN to the internal default address, 4 KRGN to the second one.
    let received = wtx[2]["received"].as_array().unwrap();
    assert_eq!(received.len(), 2);
    for n in received {
        match n["value"].as_u64().unwrap() {
            300_000_000 => assert_eq!(n["address"], INTERNAL_DEFAULT),
            400_000_000 => {
                assert_eq!(n["address"], NODE_ADDRESSES[1]);
                assert_eq!(n["change"], false);
            }
            v => panic!("unexpected note {v}"),
        }
    }

    // Four notes found; the caller drops the spent one by its nullifier.
    let notes = r["decrypted_new_notes"].as_array().unwrap();
    assert_eq!(notes.len(), 4);
    let nullifiers = r["nullifiers"].as_array().unwrap();
    let unspent: u64 = notes
        .iter()
        .filter(|n| !nullifiers.contains(&n["nullifier"]))
        .map(|n| n["value"].as_u64().unwrap())
        .sum();
    assert_eq!(unspent, 1_699_975_000);

    // Six outputs in the tree (two per tx).
    let root = call("sapling_root", json!({"tree": r["commitment_tree"]}));
    assert_eq!(root.as_str().unwrap().len(), 64);
}

#[test]
fn notes_round_trip_and_witnesses_advance() {
    let blocks: Vec<Value> = serde_json::from_str(BLOCKS).unwrap();
    let first = call(
        "handle_blocks",
        json!({"tree": "000000", "blocks": &blocks[..1], "extfvk": VIEWING_KEY, "network": "regtest", "notes": []}),
    );
    let rest = call(
        "handle_blocks",
        json!({
            "tree": first["commitment_tree"],
            "blocks": &blocks[1..],
            "extfvk": VIEWING_KEY,
            "network": "regtest",
            "notes": first["decrypted_new_notes"],
        }),
    );
    let all = scan_all();
    // Scanning in two steps gives the same tree and the same notes.
    assert_eq!(rest["commitment_tree"], all["commitment_tree"]);
    let mut notes: Vec<Value> = rest["decrypted_notes"].as_array().unwrap().clone();
    notes.extend(rest["decrypted_new_notes"].as_array().unwrap().iter().cloned());
    assert_eq!(&notes, all["decrypted_new_notes"].as_array().unwrap());
}

#[test]
fn transaction_checks_run_before_proving() {
    let r = scan_all();
    let nullifiers = r["nullifiers"].as_array().unwrap();
    let unspent: Vec<Value> = r["decrypted_new_notes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|n| !nullifiers.contains(&n["nullifier"]))
        .cloned()
        .collect();
    let base = json!({
        "notes": unspent,
        "extsk": XSK.trim(),
        "to_address": NODE_ADDRESSES[0],
        "amount": 100_000_000_000u64,
        "network": "regtest",
    });
    assert!(call_err("create_transaction", base.clone()).contains("Not enough balance"));
    let mut wrong_net = base.clone();
    wrong_net["to_address"] = json!("ks1qqqq");
    assert!(call_err("create_transaction", wrong_net).contains("Invalid address"));
    let mut memo_to_t = base.clone();
    memo_to_t["to_address"] = json!("yeiahYKSYceWZji4SMJ6sQSTYsyELJxf1T");
    memo_to_t["memo"] = json!("hi");
    assert!(call_err("create_transaction", memo_to_t).contains("memo"));

    // A transparent payment below the dust limit, as asked or once the
    // fee (25000: one spend, two shield outputs) is taken from it.
    let mut to_t = base.clone();
    to_t["to_address"] = json!("yeiahYKSYceWZji4SMJ6sQSTYsyELJxf1T");
    to_t["amount"] = json!(545);
    assert!(call_err("create_transaction", to_t.clone()).contains("below the dust limit"));
    let mut after_fee = to_t.clone();
    after_fee["amount"] = json!(25_300);
    after_fee["subtract_fee"] = json!(true);
    assert!(call_err("create_transaction", after_fee).contains("below the dust limit"));
    // At the limit it goes on to proving (whatever that answers here).
    let mut at_limit = to_t;
    at_limit["amount"] = json!(546);
    if let Err(e) = dispatch("create_transaction", &at_limit.to_string()) {
        assert!(!e.contains("dust"), "{e}");
    }
    // A shield address takes any amount.
    let mut small_to_shield = base;
    small_to_shield["amount"] = json!(545);
    if let Err(e) = dispatch("create_transaction", &small_to_shield.to_string()) {
        assert!(!e.contains("dust"), "{e}");
    }
}

#[test]
fn fees_follow_kerrigan_core() {
    assert_eq!(call("sapling_fee", json!({"spends": 0, "outputs": 2})), json!(20_000));
    assert_eq!(call("sapling_fee", json!({"spends": 1, "outputs": 2})), json!(25_000));
}

#[test]
fn checkpoint_is_the_empty_tree_before_activation() {
    let c = call("closest_checkpoint", json!({"height": 123456, "network": "main"}));
    assert_eq!(c, json!({"height": 499, "tree": "000000"}));
    let c = call("closest_checkpoint", json!({"height": 5, "network": "regtest"}));
    assert_eq!(c["height"], 0);
}

#[test]
fn ffi_roundtrip_reports_errors() {
    use std::ffi::{CStr, CString};
    let m = CString::new("no_such_method").unwrap();
    let a = CString::new("{}").unwrap();
    unsafe {
        let p = crate::kerrigan_shield_call(m.as_ptr(), a.as_ptr());
        let s = CStr::from_ptr(p).to_str().unwrap().to_string();
        crate::kerrigan_shield_free(p);
        let v: Value = serde_json::from_str(&s).unwrap();
        assert!(v["err"].as_str().unwrap().contains("unknown method"));
    }
}

/// Builds real transactions when the Sapling parameters are available
/// (`KERRIGAN_PARAMS_DIR`) and writes them to `KERRIGAN_TX_OUT` for a
/// regtest node to accept: one spending the scanned notes, one shielding
/// a UTXO given in `KERRIGAN_UTXO` (JSON `Utxo`).
#[test]
#[ignore]
fn builds_transactions_for_regtest() {
    let dir = std::env::var("KERRIGAN_PARAMS_DIR").expect("KERRIGAN_PARAMS_DIR");
    call(
        "load_prover",
        json!({"output_path": format!("{dir}/sapling-output.params"), "spend_path": format!("{dir}/sapling-spend.params")}),
    );
    let r = scan_all();
    let nullifiers = r["nullifiers"].as_array().unwrap();
    let unspent: Vec<Value> = r["decrypted_new_notes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|n| !nullifiers.contains(&n["nullifier"]))
        .cloned()
        .collect();
    let spend = call(
        "create_transaction",
        json!({
            "notes": unspent,
            "extsk": XSK.trim(),
            "to_address": NODE_ADDRESSES[1],
            "amount": 500_000_000u64,
            "network": "regtest",
            "memo": "from trekpay",
        }),
    );
    assert_eq!(spend["fee"], 25_000);
    let mut out = vec![spend["txhex"].as_str().unwrap().to_string()];
    if let Ok(utxo) = std::env::var("KERRIGAN_UTXO") {
        let utxo: Value = serde_json::from_str(&utxo).unwrap();
        let shield = call(
            "create_transaction",
            json!({
                "utxos": [utxo],
                "extsk": XSK.trim(),
                "to_address": NODE_ADDRESSES[0],
                "change_address": std::env::var("KERRIGAN_CHANGE").unwrap(),
                "amount": 100_000_000u64,
                "network": "regtest",
            }),
        );
        assert_eq!(shield["fee"], 20_000);
        out.push(shield["txhex"].as_str().unwrap().to_string());
    }
    std::fs::write(std::env::var("KERRIGAN_TX_OUT").unwrap(), out.join("\n")).unwrap();
}
