//! Building Kerrigan Sapling transactions (type 10).
//!
//! Like Kerrigan Core (`SaplingTransactionBuilder::Build`): the Sapling
//! bundle is proven, signed over Kerrigan's Sapling sighash, placed in
//! the extra payload, and only then are transparent inputs signed (their
//! legacy sighash covers the payload).
use sapling::builder::{BundleType, Builder};
use sapling::circuit::{OutputParameters, SpendParameters};
use sapling::value::NoteValue;
use sapling::zip32::ExtendedSpendingKey;
use sapling::Anchor;
use secp256k1::{Message, PublicKey, SecretKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zip32::Scope;

use crate::keys::{decode_destination, decode_extsk, transparent_script, Destination};
use crate::network::Network;
use crate::prover;
use crate::scan::{JSSpendableNote, NoteScope, SpendableNote, ViewingKeys, ZIP212};
use crate::tx::{
    display_hash, OutputDesc, SaplingPayload, SpendDesc, Transaction, TxIn, TxOut, MAX_SAPLING_TX_SIZE,
    MAX_SHIELDED_DESCRIPTIONS, SIGHASH_ALL,
};
use crate::Error;

/// Kerrigan Core `CalculateSaplingFee`: 0.0001 KRGN plus 0.00005 per
/// spend and per shield output. The mempool rejects anything less.
pub fn sapling_fee(spends: usize, outputs: usize) -> u64 {
    10_000 + 5_000 * spends as u64 + 5_000 * outputs as u64
}

// On-wire sizes, for the size estimate (Kerrigan Core `sapling_send.cpp`).
const SPEND_DESCRIPTION_SIZE: usize = 384;
const OUTPUT_DESCRIPTION_SIZE: usize = 948;
const TRANSPARENT_INPUT_SIZE: usize = 148;
const TRANSPARENT_OUTPUT_SIZE: usize = 34;
const SAPLING_TX_OVERHEAD: usize = 120;
/// Minimum relay fee: 1 sat per byte.
const MIN_RELAY_FEE_PER_BYTE: u64 = 1;
/// Transparent outputs below this are dust (Kerrigan Core `IsDust` for
/// P2PKH at the 3000 sat/kB dust relay fee): change that small goes to the
/// fee instead, and a payment that small is refused.
const DUST: u64 = 546;
/// The node won't relay a transparent payment below [DUST].
const BELOW_DUST: &str = "Amount after the fee is below the dust limit";
/// Shield outputs are padded to at least two.
const MIN_SHIELD_OUTPUTS: usize = 2;

fn estimated_size(t_in: usize, t_out: usize, spends: usize, outputs: usize) -> usize {
    SAPLING_TX_OVERHEAD
        + t_in * TRANSPARENT_INPUT_SIZE
        + t_out * TRANSPARENT_OUTPUT_SIZE
        + spends * SPEND_DESCRIPTION_SIZE
        + outputs * OUTPUT_DESCRIPTION_SIZE
}

#[derive(Serialize, Deserialize)]
pub struct JSTransaction {
    pub txid: String,
    pub txhex: String,
    /// Nullifiers of spent notes, or "txid,vout" of spent UTXOs.
    pub nullifiers: Vec<String>,
    pub fee: u64,
    pub amount: u64,
}

#[derive(Serialize, Deserialize)]
pub struct Utxo {
    pub txid: String,
    pub vout: u32,
    pub amount: u64,
    /// 32-byte secret key, hex.
    pub private_key: String,
    /// scriptPubKey of the spent output (P2PKH), hex.
    pub script: String,
}

#[derive(Serialize, Deserialize)]
pub struct JSTxOptions {
    pub notes: Option<Vec<JSSpendableNote>>,
    pub utxos: Option<Vec<Utxo>>,
    pub extsk: String,
    pub to_address: String,
    /// Where change goes. Empty: the wallet's internal shield address when
    /// spending notes (as Kerrigan Core does). Spending UTXOs needs a
    /// transparent change address.
    #[serde(default)]
    pub change_address: String,
    pub amount: u64,
    pub network: Network,
    #[serde(default)]
    pub memo: String,
    /// Spend every given note/UTXO (coin control) instead of only as
    /// many as the amount needs.
    #[serde(default)]
    pub use_all_inputs: bool,
    /// The recipient pays the fee: it receives `amount - fee`.
    #[serde(default)]
    pub subtract_fee: bool,
    /// More transparent outputs paid besides `to_address` (shield notes
    /// only), e.g. a little kept transparent for a masternode
    /// registration fee.
    #[serde(default)]
    pub extra_outputs: Vec<ExtraOutput>,
}

#[derive(Serialize, Deserialize)]
pub struct ExtraOutput {
    /// Transparent address, or `script:<hex>`.
    pub address: String,
    pub amount: u64,
}

/// How inputs are chosen and who pays the fee.
#[derive(Clone, Copy)]
struct Selection {
    use_all: bool,
    subtract_fee: bool,
}

impl Selection {
    fn needed(&self, amount: u64, fee: u64) -> u64 {
        if self.subtract_fee {
            amount
        } else {
            amount + fee
        }
    }

    /// Final amount sent and change, given the selected `total`.
    fn settle(&self, total: u64, amount: &mut u64, fee: u64) -> Result<u64, Error> {
        if self.subtract_fee {
            if total < *amount || *amount <= fee {
                return Err("Not enough balance".into());
            }
            *amount -= fee;
        } else if total < *amount + fee {
            return Err("Not enough balance to pay the fee".into());
        }
        Ok(total - *amount - fee)
    }
}

/// ZIP 302 memo bytes: UTF-8 text padded with zeros, or "no memo" (0xF6).
fn memo_bytes(memo: &str) -> Result<[u8; 512], Error> {
    let mut out = [0u8; 512];
    if memo.is_empty() {
        out[0] = 0xf6;
        return Ok(out);
    }
    if memo.len() > 512 {
        return Err("Memo too long (max 512 bytes)".into());
    }
    out[..memo.len()].copy_from_slice(memo.as_bytes());
    Ok(out)
}

pub fn create_transaction(o: JSTxOptions) -> Result<JSTransaction, Error> {
    let selection = Selection { use_all: o.use_all_inputs, subtract_fee: o.subtract_fee };
    let xsk = decode_extsk(&o.extsk)?;
    let to = decode_destination(&o.to_address, o.network)?;
    if !o.memo.is_empty() && matches!(to, Destination::Transparent(_)) {
        return Err("A memo can only be sent to a shield address".into());
    }
    let mut extra = Vec::new();
    for e in &o.extra_outputs {
        match decode_destination(&e.address, o.network)? {
            Destination::Transparent(script) if e.amount > 0 => extra.push(TxOut { value: e.amount as i64, script }),
            Destination::Transparent(_) => return Err("Extra outputs need an amount".into()),
            Destination::Shield(_) => return Err("Extra outputs must be transparent".into()),
        }
    }
    if !extra.is_empty() && o.subtract_fee {
        return Err("Extra outputs can't be combined with subtracting the fee".into());
    }
    match (o.notes, o.utxos) {
        (Some(notes), None) => {
            spend_notes(&xsk, notes, to, extra, &o.change_address, o.amount, o.network, &o.memo, selection)
        }
        (None, Some(_)) if !extra.is_empty() => Err("Extra outputs need shield notes".into()),
        (None, Some(utxos)) => shield_utxos(&xsk, utxos, to, &o.change_address, o.amount, o.network, &o.memo, selection),
        (Some(_), Some(_)) => Err("Notes and UTXOs were both provided".into()),
        (None, None) => Err("No input provided".into()),
    }
}

/// Spend shield notes to a shield or transparent address.
#[allow(clippy::too_many_arguments)]
fn spend_notes(
    xsk: &ExtendedSpendingKey,
    notes: Vec<JSSpendableNote>,
    to: Destination,
    extra: Vec<TxOut>,
    change_address: &str,
    mut amount: u64,
    network: Network,
    memo: &str,
    selection: Selection,
) -> Result<JSTransaction, Error> {
    let extra_total: u64 = extra.iter().map(|o| o.value as u64).sum();
    let dfvk = xsk.to_diversifiable_full_viewing_key();
    let keys = ViewingKeys::new(dfvk.clone());
    let mut notes = notes.iter().map(SpendableNote::from_js).collect::<Result<Vec<_>, _>>()?;
    // Largest first: fewer spends, lower fee (Kerrigan Core does the same).
    notes.sort_by_key(|n| std::cmp::Reverse(n.note.value().inner()));
    let first = notes.first().ok_or("No shield notes to spend")?;
    let anchor = Anchor::from(first.witness.root());

    let change_to = if change_address.is_empty() {
        Destination::Shield(dfvk.change_address().1)
    } else {
        decode_destination(change_address, network)?
    };
    let t_out = usize::from(matches!(to, Destination::Transparent(_)))
        + usize::from(matches!(change_to, Destination::Transparent(_)))
        + extra.len();
    let shield_out = MIN_SHIELD_OUTPUTS
        .max(usize::from(matches!(to, Destination::Shield(_))) + usize::from(matches!(change_to, Destination::Shield(_))));

    let mut builder = Builder::new(ZIP212, BundleType::DEFAULT, anchor);
    let mut total = 0;
    let mut fee = 0;
    let mut nullifiers = Vec::new();
    for n in &notes {
        let fvk = match n.scope {
            NoteScope::External => dfvk.fvk().clone(),
            NoteScope::Internal => dfvk.to_internal_fvk(),
        };
        let path = n.witness.path().ok_or("Note has no Merkle path")?;
        builder.add_spend(fvk, n.note.clone(), path).map_err(|e| format!("Cannot spend note: {e:?}"))?;
        nullifiers.push(keys.nullifier(&n.note, n.scope, &n.witness));
        total += n.note.value().inner();
        let spends = nullifiers.len();
        fee = fee_for(0, t_out, spends, shield_out);
        if !selection.use_all && total >= selection.needed(amount, fee) + extra_total {
            break;
        }
    }
    if nullifiers.len() > MAX_SHIELDED_DESCRIPTIONS {
        return Err("Too many notes for one transaction; send a smaller amount".into());
    }
    if total < extra_total {
        return Err("Not enough balance".into());
    }
    let change = selection.settle(total - extra_total, &mut amount, fee)?;
    if matches!(to, Destination::Transparent(_)) && amount < DUST {
        return Err(BELOW_DUST.into());
    }

    let ovk = dfvk.to_ovk(Scope::External);
    let mut vout = Vec::new();
    match &to {
        Destination::Shield(addr) => builder
            .add_output(Some(ovk), *addr, NoteValue::from_raw(amount), memo_bytes(memo)?)
            .map_err(|e| format!("Cannot add output: {e:?}"))?,
        Destination::Transparent(script) => vout.push(TxOut { value: amount as i64, script: script.clone() }),
    }
    vout.extend(extra);
    if change > 0 {
        match &change_to {
            Destination::Shield(addr) => builder
                .add_output(Some(dfvk.to_ovk(Scope::Internal)), *addr, NoteValue::from_raw(change), memo_bytes("")?)
                .map_err(|e| format!("Cannot add change: {e:?}"))?,
            Destination::Transparent(_) if change < DUST => fee += change,
            Destination::Transparent(script) => vout.push(TxOut { value: change as i64, script: script.clone() }),
        }
    }

    let xsk_internal = xsk.derive_internal().ok_or("Cannot derive the internal key")?;
    let tx = Transaction { version: 3, tx_type: 10, vin: Vec::new(), vout, lock_time: 0, extra_payload: Vec::new() };
    let (tx, _) = prove_and_sign(tx, builder, &[xsk.clone(), xsk_internal], &[])?;
    finish(tx, nullifiers, fee, amount)
}

/// Spend transparent UTXOs to a shield address (shielding).
#[allow(clippy::too_many_arguments)]
fn shield_utxos(
    xsk: &ExtendedSpendingKey,
    mut utxos: Vec<Utxo>,
    to: Destination,
    change_address: &str,
    mut amount: u64,
    network: Network,
    memo: &str,
    selection: Selection,
) -> Result<JSTransaction, Error> {
    let Destination::Shield(to) = to else {
        return Err("Transparent coins go to transparent addresses with a regular transaction".into());
    };
    utxos.sort_by_key(|u| std::cmp::Reverse(u.amount));
    let change_script =
        if change_address.is_empty() { None } else { Some(transparent_script(change_address, network)?) };

    let mut total = 0;
    let mut fee = 0;
    let mut used = Vec::new();
    for u in &utxos {
        used.push(u);
        total += u.amount;
        fee = fee_for(used.len(), 1, 0, MIN_SHIELD_OUTPUTS);
        if !selection.use_all && total >= selection.needed(amount, fee) {
            break;
        }
    }
    let mut change = selection.settle(total, &mut amount, fee)?;
    if change > 0 && change < DUST {
        fee += change;
        change = 0;
    }

    let dfvk = xsk.to_diversifiable_full_viewing_key();
    let mut builder = Builder::new(ZIP212, BundleType::DEFAULT, Anchor::empty_tree());
    builder
        .add_output(Some(dfvk.to_ovk(Scope::External)), to, NoteValue::from_raw(amount), memo_bytes(memo)?)
        .map_err(|e| format!("Cannot add output: {e:?}"))?;

    let mut vin = Vec::new();
    let mut signing = Vec::new();
    for u in &used {
        let mut prev_txid: [u8; 32] =
            hex::decode(&u.txid).ok().and_then(|b| b.try_into().ok()).ok_or("Invalid UTXO txid")?;
        prev_txid.reverse();
        vin.push(TxIn { prev_txid, prev_vout: u.vout, script_sig: Vec::new(), sequence: 0xffff_ffff });
        signing.push(TransparentSigner::new(u)?);
    }
    let mut vout = Vec::new();
    if change > 0 {
        let script = change_script.ok_or("A change address is needed")?;
        vout.push(TxOut { value: change as i64, script });
    }
    let tx = Transaction { version: 3, tx_type: 10, vin, vout, lock_time: 0, extra_payload: Vec::new() };
    let (tx, _) = prove_and_sign(tx, builder, &[], &signing)?;
    let spent = used.iter().map(|u| format!("{},{}", u.txid, u.vout)).collect();
    finish(tx, spent, fee, amount)
}

/// Fee for a transaction with these counts: Kerrigan's Sapling fee, and
/// never less than the minimum relay fee for its size.
fn fee_for(t_in: usize, t_out: usize, spends: usize, outputs: usize) -> u64 {
    let size = estimated_size(t_in, t_out, spends, outputs) as u64;
    sapling_fee(spends, outputs).max(size * MIN_RELAY_FEE_PER_BYTE)
}

fn finish(tx: Transaction, nullifiers: Vec<String>, fee: u64, amount: u64) -> Result<JSTransaction, Error> {
    let bytes = tx.write();
    if bytes.len() > MAX_SAPLING_TX_SIZE {
        return Err("The transaction is too large; send a smaller amount".into());
    }
    Ok(JSTransaction {
        txid: display_hash(&crate::tx::sha256d(&bytes)),
        txhex: hex::encode(bytes),
        nullifiers,
        fee,
        amount,
    })
}

/// Signs one P2PKH input.
pub struct TransparentSigner {
    key: SecretKey,
    pubkey: [u8; 33],
    script: Vec<u8>,
}

impl TransparentSigner {
    pub(crate) fn new(u: &Utxo) -> Result<Self, Error> {
        let key: [u8; 32] =
            hex::decode(&u.private_key).ok().and_then(|b| b.try_into().ok()).ok_or("Invalid UTXO key")?;
        let key = SecretKey::from_secret_bytes(key).map_err(|_| "Invalid UTXO key")?;
        let pubkey = PublicKey::from_secret_key(&key).serialize();
        let script = hex::decode(&u.script).map_err(|_| "Invalid UTXO script")?;
        let hash: [u8; 20] = ripemd::Ripemd160::digest(Sha256::digest(pubkey)).into();
        let expected = [&[0x76, 0xa9, 0x14][..], &hash, &[0x88, 0xac]].concat();
        if script != expected {
            return Err("UTXO script does not match its key (only P2PKH can be spent)".into());
        }
        Ok(Self { key, pubkey, script })
    }

    /// The spent output's script (the script code signed).
    pub(crate) fn script(&self) -> &[u8] {
        &self.script
    }

    pub(crate) fn script_sig(&self, sighash: [u8; 32]) -> Vec<u8> {
        let sig = self.key.sign_ecdsa(Message::from_digest(sighash));
        let mut der = sig.serialize_der().to_vec();
        der.push(SIGHASH_ALL as u8);
        let mut s = Vec::with_capacity(der.len() + 35);
        s.push(der.len() as u8);
        s.extend_from_slice(&der);
        s.push(33);
        s.extend_from_slice(&self.pubkey);
        s
    }
}

/// Prove the bundle, sign it over the Sapling sighash, set the payload,
/// then sign transparent inputs. Returns the transaction and its bundle's
/// value balance.
fn prove_and_sign(
    mut tx: Transaction,
    builder: Builder,
    extsks: &[ExtendedSpendingKey],
    signers: &[TransparentSigner],
) -> Result<(Transaction, i64), Error> {
    let (spend_params, output_params) = prover::get()?;
    let mut rng = rand::rng();
    let (bundle, _) = builder
        .build::<SpendParameters, OutputParameters, _, i64>(extsks, &mut rng)
        .map_err(|e| format!("Cannot build the shield bundle: {e:?}"))?
        .ok_or("Empty shield bundle")?;
    let bundle = bundle.create_proofs(spend_params, output_params, &mut rng, ());

    let outputs: Vec<OutputDesc> = bundle
        .shielded_outputs()
        .iter()
        .map(|o| OutputDesc {
            cv: o.cv().to_bytes(),
            cmu: o.cmu().to_bytes(),
            ephemeral_key: o.ephemeral_key().0,
            enc_ciphertext: *o.enc_ciphertext(),
            out_ciphertext: *o.out_ciphertext(),
            zkproof: *o.zkproof(),
        })
        .collect();
    let unsigned_spends: Vec<SpendDesc> = bundle
        .shielded_spends()
        .iter()
        .map(|s| SpendDesc {
            cv: s.cv().to_bytes(),
            anchor: s.anchor().to_bytes(),
            nullifier: s.nullifier().0,
            rk: (*s.rk()).into(),
            zkproof: *s.zkproof(),
            spend_auth_sig: [0; 64],
        })
        .collect();
    let value_balance = *bundle.value_balance();
    let sighash = tx.sapling_sighash(&unsigned_spends, &outputs, value_balance);

    let asks: Vec<_> = extsks.iter().map(|k| k.expsk().ask().clone()).collect();
    let bundle = bundle
        .apply_signatures(&mut rng, sighash, &asks)
        .map_err(|e| format!("Cannot sign the shield bundle: {e:?}"))?;
    let spends = unsigned_spends
        .into_iter()
        .zip(bundle.shielded_spends())
        .map(|(mut d, s)| {
            d.spend_auth_sig = (*s.spend_auth_sig()).into();
            d
        })
        .collect();
    tx.set_sapling(&SaplingPayload {
        spends,
        outputs,
        value_balance,
        binding_sig: bundle.authorization().binding_sig.into(),
    });

    for (i, signer) in signers.iter().enumerate() {
        let sighash = tx.transparent_sighash(i, &signer.script, SIGHASH_ALL);
        tx.vin[i].script_sig = signer.script_sig(sighash);
    }
    Ok((tx, value_balance))
}
