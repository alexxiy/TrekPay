//! Note scanning: finds the wallet's notes in blocks of raw Kerrigan
//! transactions, keeps their witnesses current and reports the
//! transactions that touch the wallet.
//!
//! The wallet state (commitment tree, notes) is owned by the caller and
//! passed in and out as serialisable data.
use rayon::prelude::*;
use sapling::note::ExtractedNoteCommitment;
use sapling::note_encryption::{
    try_sapling_note_decryption, try_sapling_output_recovery, PreparedIncomingViewingKey, Zip212Enforcement,
};
use sapling::value::{NoteValue, ValueCommitment};
use sapling::zip32::DiversifiableFullViewingKey;
use sapling::{Node, Note, PaymentAddress, Rseed};
use serde::{Deserialize, Serialize};
use zcash_note_encryption::EphemeralKeyBytes;
use zip32::Scope;

use crate::keys::{decode_dfvk, encode_address};
use crate::network::Network;
use crate::tree::{read_tree, read_witness, write_tree, write_witness, Witness};
use crate::tx::{display_hash, read_compact_size, sha256d, OutputDesc, Reader, Transaction, MAX_SHIELDED_DESCRIPTIONS};
use crate::Error;

/// Kerrigan notes use the pre-ZIP 212 plaintext (Kerrigan Core keeps
/// Canopy disabled).
pub const ZIP212: Zip212Enforcement = Zip212Enforcement::Off;

/// A spendable note as the caller stores it.
#[derive(Clone, Serialize, Deserialize)]
pub struct JSSpendableNote {
    /// Value in satoshis.
    pub value: u64,
    /// Recipient address (display only).
    pub address: String,
    /// Recipient address, 43 raw bytes in hex.
    pub recipient: String,
    /// Note commitment trapdoor (pre-ZIP 212 rseed), hex.
    pub rseed: String,
    /// `external` for payments to the wallet's addresses, `internal` for change.
    pub scope: NoteScope,
    pub witness: String,
    pub nullifier: String,
    pub memo: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NoteScope {
    External,
    Internal,
}

impl From<NoteScope> for Scope {
    fn from(s: NoteScope) -> Self {
        match s {
            NoteScope::External => Scope::External,
            NoteScope::Internal => Scope::Internal,
        }
    }
}

/// A note with its witness, decoded.
pub struct SpendableNote {
    pub note: Note,
    pub scope: NoteScope,
    pub witness: Witness,
    pub nullifier: String,
    pub memo: Option<String>,
}

impl SpendableNote {
    pub fn from_js(n: &JSSpendableNote) -> Result<Self, Error> {
        let recipient: [u8; 43] = hex::decode(&n.recipient)
            .ok()
            .and_then(|b| b.try_into().ok())
            .ok_or("Invalid note recipient")?;
        let recipient = PaymentAddress::from_bytes(&recipient).ok_or("Invalid note recipient")?;
        let rseed: [u8; 32] = hex::decode(&n.rseed).ok().and_then(|b| b.try_into().ok()).ok_or("Invalid note rseed")?;
        let rcm = Option::from(jubjub::Fr::from_bytes(&rseed)).ok_or("Invalid note rseed")?;
        Ok(Self {
            note: Note::from_parts(recipient, NoteValue::from_raw(n.value), Rseed::BeforeZip212(rcm)),
            scope: n.scope,
            witness: read_witness(&n.witness)?,
            nullifier: n.nullifier.clone(),
            memo: n.memo.clone(),
        })
    }

    pub fn to_js(&self, network: Network) -> JSSpendableNote {
        let rseed = match self.note.rseed() {
            Rseed::BeforeZip212(rcm) => rcm.to_bytes(),
            Rseed::AfterZip212(r) => *r,
        };
        JSSpendableNote {
            value: self.note.value().inner(),
            address: encode_address(&self.note.recipient(), network),
            recipient: hex::encode(self.note.recipient().to_bytes()),
            rseed: hex::encode(rseed),
            scope: self.scope,
            witness: write_witness(&self.witness),
            nullifier: self.nullifier.clone(),
            memo: self.memo.clone(),
        }
    }
}

#[derive(Serialize, Deserialize)]
pub struct Block {
    /// Hex of each shield transaction: a full raw one (the bridge's `raw`
    /// stream format) or a compact packet (its `compact` format, see
    /// [`COMPACT_TX`]).
    pub txs: Vec<String>,
}

/// A note received by the wallet in a specific transaction.
#[derive(Serialize, Deserialize)]
pub struct ReceivedNote {
    pub value: u64,
    pub address: String,
    pub memo: Option<String>,
    pub nullifier: String,
    /// Index of the note's output among the tx's shield outputs.
    pub index: u32,
    /// Change to the wallet's internal address.
    pub change: bool,
}

/// A shield output this wallet sent to someone else, recovered with the
/// wallet's outgoing viewing key.
#[derive(Serialize, Deserialize, Clone)]
pub struct SentNote {
    pub value: u64,
    pub address: String,
    pub memo: Option<String>,
    pub index: u32,
}

/// A transaction that touches the wallet (receives a note, spends one,
/// or sent shield outputs recoverable with our outgoing viewing key).
#[derive(Serialize, Deserialize)]
pub struct WalletTxDetail {
    /// Empty for a compact packet, which has no txid: the caller finds
    /// the transaction in its block by `nullifiers` and `commitments`.
    pub txid: String,
    pub hex: String,
    /// Index of the transaction's block in the blocks passed in.
    #[serde(default)]
    pub block: u32,
    pub received: Vec<ReceivedNote>,
    pub sent: Vec<SentNote>,
    /// All nullifiers revealed by the tx (the caller matches its own).
    pub nullifiers: Vec<String>,
    /// Note commitments (cmu) of all the tx's shield outputs, in order.
    #[serde(default)]
    pub commitments: Vec<String>,
    /// valueBalance of the Sapling bundle: value moved out of the shield
    /// pool. 0 for a compact packet, which doesn't carry it.
    pub value_balance: i64,
}

#[derive(Serialize, Deserialize)]
pub struct HandleBlocksResult {
    pub decrypted_notes: Vec<JSSpendableNote>,
    pub decrypted_new_notes: Vec<JSSpendableNote>,
    pub nullifiers: Vec<String>,
    pub commitment_tree: String,
    pub wallet_transactions: Vec<WalletTxDetail>,
}

/// ZIP 302 text memo, without its zero padding; `None` for an empty or
/// non-text memo.
pub fn memo_text(memo: &[u8; 512]) -> Option<String> {
    if memo[0] > 0xf4 {
        return None;
    }
    let end = memo.iter().rposition(|&b| b != 0).map(|i| i + 1).unwrap_or(0);
    let text = std::str::from_utf8(&memo[..end]).ok()?;
    (!text.is_empty()).then(|| text.to_string())
}

/// What an output is to the wallet.
enum Found {
    Ours(Note, NoteScope, Option<String>),
    Sent(Note, Option<String>),
    Other,
}

pub struct ViewingKeys {
    dfvk: DiversifiableFullViewingKey,
    ivk_external: PreparedIncomingViewingKey,
    ivk_internal: PreparedIncomingViewingKey,
}

impl ViewingKeys {
    pub fn new(dfvk: DiversifiableFullViewingKey) -> Self {
        Self {
            ivk_external: PreparedIncomingViewingKey::new(&dfvk.to_ivk(Scope::External)),
            ivk_internal: PreparedIncomingViewingKey::new(&dfvk.to_ivk(Scope::Internal)),
            dfvk,
        }
    }

    fn classify(&self, o: &OutputDesc) -> Result<Found, Error> {
        let cv = Option::from(ValueCommitment::from_bytes_not_small_order(&o.cv)).ok_or("Invalid output cv")?;
        let cmu = Option::from(ExtractedNoteCommitment::from_bytes(&o.cmu)).ok_or("Invalid output cmu")?;
        let output = sapling::bundle::OutputDescription::from_parts(
            cv,
            cmu,
            EphemeralKeyBytes(o.ephemeral_key),
            o.enc_ciphertext,
            o.out_ciphertext,
            o.zkproof,
        );
        for (ivk, scope) in [(&self.ivk_external, NoteScope::External), (&self.ivk_internal, NoteScope::Internal)] {
            if let Some((note, _, memo)) = try_sapling_note_decryption(ivk, &output, ZIP212) {
                return Ok(Found::Ours(note, scope, memo_text(&memo)));
            }
        }
        let ovk = self.dfvk.to_ovk(Scope::External);
        Ok(match try_sapling_output_recovery(&ovk, &output, ZIP212) {
            Some((note, _, memo)) => Found::Sent(note, memo_text(&memo)),
            None => Found::Other,
        })
    }

    pub fn nullifier(&self, note: &Note, scope: NoteScope, witness: &Witness) -> String {
        let position = u64::from(witness.witnessed_position());
        hex::encode(note.nf(&self.dfvk.to_nk(scope.into()), position).0)
    }
}

/// Packet type of a transaction in the bridge's `compact` stream: the
/// nullifiers and outputs of its Sapling bundle without proofs or
/// signatures. A full raw transaction (nVersion 3) starts with 0x03.
pub const COMPACT_TX: u8 = 0x04;

/// The Sapling parts of a transaction from the shield stream.
struct StreamTx {
    /// None for a compact packet.
    txid: Option<[u8; 32]>,
    nullifiers: Vec<[u8; 32]>,
    outputs: Vec<OutputDesc>,
    value_balance: i64,
}

/// A compact packet: `[0x04][spends][outputs]` (CompactSize each), then
/// 32 bytes of nullifier per spend and per output cv, cmu, epk (32 each),
/// enc_ciphertext and out_ciphertext (the bridge's `encode_compact_tx`).
fn parse_compact_tx(data: &[u8]) -> Result<StreamTx, Error> {
    const COMPACT_OUTPUT_SIZE: usize = 3 * 32 + 580 + 80;
    let mut r = Reader::new(data);
    r.u8()?;
    let spends = read_compact_size(&mut r)?;
    let outputs = read_compact_size(&mut r)?;
    if spends > MAX_SHIELDED_DESCRIPTIONS || outputs > MAX_SHIELDED_DESCRIPTIONS {
        return Err("Compact packet has too many spends or outputs".into());
    }
    if r.remaining() != spends * 32 + outputs * COMPACT_OUTPUT_SIZE {
        return Err("Compact packet has the wrong length".into());
    }
    let nullifiers = (0..spends).map(|_| r.array()).collect::<Result<Vec<_>, _>>()?;
    let outputs = (0..outputs)
        .map(|_| {
            Ok(OutputDesc {
                cv: r.array()?,
                cmu: r.array()?,
                ephemeral_key: r.array()?,
                enc_ciphertext: r.array()?,
                out_ciphertext: r.array()?,
                // Not in the packet, and not needed to find notes.
                zkproof: [0; 192],
            })
        })
        .collect::<Result<Vec<_>, Error>>()?;
    r.finish()?;
    Ok(StreamTx { txid: None, nullifiers, outputs, value_balance: 0 })
}

/// A stream transaction's Sapling parts, or `None` for a transaction
/// without a Sapling bundle.
fn parse_stream_tx(tx_hex: &str) -> Result<Option<StreamTx>, Error> {
    let bytes = hex::decode(tx_hex).map_err(|_| "Tx hex is invalid".to_string())?;
    if bytes.first() == Some(&COMPACT_TX) {
        return parse_compact_tx(&bytes).map(Some);
    }
    Ok(Transaction::read(&bytes)?.sapling()?.map(|s| StreamTx {
        txid: Some(sha256d(&bytes)),
        nullifiers: s.spends.iter().map(|d| d.nullifier).collect(),
        outputs: s.outputs,
        value_balance: s.value_balance,
    }))
}

/// Scan the bridge's shield stream: full raw transactions (`raw` format)
/// or compact packets (`compact` format), which give the same notes, tree
/// and nullifiers. A compact wallet transaction comes back without txid.
pub fn handle_blocks(
    tree_hex: &str,
    blocks: Vec<Block>,
    enc_dfvk: &str,
    network: Network,
    notes: Vec<JSSpendableNote>,
) -> Result<HandleBlocksResult, Error> {
    let mut tree = read_tree(tree_hex)?;
    let keys = ViewingKeys::new(decode_dfvk(enc_dfvk)?);
    let mut existing = notes.iter().map(SpendableNote::from_js).collect::<Result<Vec<_>, _>>()?;

    let hexes: Vec<(u32, String)> = blocks
        .into_iter()
        .enumerate()
        .flat_map(|(i, b)| b.txs.into_iter().map(move |h| (i as u32, h)))
        .collect();
    let txs = hexes.par_iter().map(|(_, h)| parse_stream_tx(h)).collect::<Result<Vec<_>, Error>>()?;

    // Trial decryption is the expensive part: run it for all outputs at once.
    let found = txs
        .par_iter()
        .map(|tx| {
            tx.as_ref()
                .map(|t| t.outputs.iter().map(|o| keys.classify(o)).collect::<Result<Vec<_>, _>>())
                .unwrap_or(Ok(Vec::new()))
        })
        .collect::<Result<Vec<_>, Error>>()?;

    let mut new_notes: Vec<SpendableNote> = Vec::new();
    let mut nullifiers = Vec::new();
    let mut wallet_transactions = Vec::new();
    for ((tx, found), (block, hex_tx)) in txs.iter().zip(found).zip(&hexes) {
        let Some(tx) = tx else { continue };
        let tx_nullifiers: Vec<String> = tx.nullifiers.iter().map(hex::encode).collect();
        let mut received = Vec::new();
        let mut sent = Vec::new();
        for (i, (output, found)) in tx.outputs.iter().zip(found).enumerate() {
            let cmu = Option::from(ExtractedNoteCommitment::from_bytes(&output.cmu)).ok_or("Invalid output cmu")?;
            let node = Node::from_cmu(&cmu);
            tree.append(node).map_err(|_| "Commitment tree is full")?;
            for n in existing.iter_mut().chain(new_notes.iter_mut()) {
                n.witness.append(node).map_err(|_| "Witness is full")?;
            }
            match found {
                Found::Ours(note, scope, memo) => {
                    let witness = Witness::from_tree(tree.clone()).ok_or("Empty commitment tree")?;
                    let nullifier = keys.nullifier(&note, scope, &witness);
                    received.push(ReceivedNote {
                        value: note.value().inner(),
                        address: encode_address(&note.recipient(), network),
                        memo: memo.clone(),
                        nullifier: nullifier.clone(),
                        index: i as u32,
                        change: scope == NoteScope::Internal,
                    });
                    new_notes.push(SpendableNote { note, scope, witness, nullifier, memo });
                }
                Found::Sent(note, memo) => sent.push(SentNote {
                    value: note.value().inner(),
                    address: encode_address(&note.recipient(), network),
                    memo,
                    index: i as u32,
                }),
                Found::Other => {}
            }
        }
        let spends_ours = existing
            .iter()
            .chain(new_notes.iter())
            .any(|n| tx_nullifiers.contains(&n.nullifier));
        if !received.is_empty() || !sent.is_empty() || spends_ours {
            wallet_transactions.push(WalletTxDetail {
                txid: tx.txid.as_ref().map(display_hash).unwrap_or_default(),
                hex: hex_tx.clone(),
                block: *block,
                received,
                sent,
                nullifiers: tx_nullifiers.clone(),
                commitments: tx.outputs.iter().map(|o| hex::encode(o.cmu)).collect(),
                value_balance: tx.value_balance,
            });
        }
        nullifiers.extend(tx_nullifiers);
    }

    Ok(HandleBlocksResult {
        decrypted_notes: existing.iter().map(|n| n.to_js(network)).collect(),
        decrypted_new_notes: new_notes.iter().map(|n| n.to_js(network)).collect(),
        nullifiers,
        commitment_tree: write_tree(&tree),
        wallet_transactions,
    })
}
