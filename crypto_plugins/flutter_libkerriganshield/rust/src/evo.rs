//! Deterministic masternodes (Dash DIP3) as Kerrigan Core runs them: BLS
//! operator keys, the compact ECDSA signatures Core checks, and the
//! provider transactions a wallet sends (register, update service,
//! update registrar, revoke).
//!
//! Formats follow Kerrigan Core `src/evo/providertx.h` at version 2
//! (`ProTxVersion::BasicBLS`): the BLS basic scheme is active on every
//! Kerrigan network, and extended addresses (V24) never are.
use std::net::{IpAddr, SocketAddr};

use bls12_381::hash_to_curve::{ExpandMsgXmd, HashToCurve};
use bls12_381::{pairing, G1Affine, G1Projective, G2Affine, G2Projective, Scalar};
use secp256k1::ecdsa::RecoverableSignature;
use secp256k1::{Message, SecretKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::build::{TransparentSigner, Utxo};
use crate::keys::transparent_script;
use crate::network::Network;
use crate::tx::{display_hash, sha256d, write_bytes, Transaction, TxIn, TxOut, SIGHASH_ALL};
use crate::Error;

/// Special transaction types (`TRANSACTION_PROVIDER_*`).
const TX_PROVIDER_REGISTER: u16 = 1;
const TX_PROVIDER_UPDATE_SERVICE: u16 = 2;
const TX_PROVIDER_UPDATE_REGISTRAR: u16 = 3;
const TX_PROVIDER_UPDATE_REVOKE: u16 = 4;

/// `ProTxVersion::BasicBLS`.
const PROTX_VERSION: u16 = 2;

/// Message signing magic (`CMessageSigner`).
pub const MESSAGE_MAGIC: &str = "DarkCoin Signed Message:\n";

/// Hash-to-curve suite of the BLS basic scheme (dashbls `BasicSchemeMPL`).
const BLS_DST: &[u8] = b"BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_";

const DUST: u64 = 546;
const MIN_FEE: u64 = 1_000;
const P2PKH_INPUT_SIZE: usize = 148;
const P2PKH_OUTPUT_SIZE: usize = 34;
const TX_OVERHEAD: usize = 12;

// ---------------------------------------------------------------------------
// BLS operator keys

fn hmac_sha256(key: &[u8], data: &[&[u8]]) -> [u8; 32] {
    let mut k = [0u8; 64];
    if key.len() > 64 {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut inner = Sha256::new();
    inner.update(k.map(|b| b ^ 0x36));
    for d in data {
        inner.update(d);
    }
    let mut outer = Sha256::new();
    outer.update(k.map(|b| b ^ 0x5c));
    outer.update(inner.finalize());
    outer.finalize().into()
}

/// BLS secret key from input key material, as the IETF BLS signature
/// draft's `KeyGen` (dashbls `BasicSchemeMPL::KeyGen`).
pub fn bls_keygen(ikm: &[u8]) -> Result<Scalar, Error> {
    if ikm.len() < 32 {
        return Err("BLS key material must be at least 32 bytes".into());
    }
    let mut salt: [u8; 32] = Sha256::digest(b"BLS-SIG-KEYGEN-SALT-").into();
    loop {
        // HKDF-Extract(salt, IKM || I2OSP(0, 1)), then HKDF-Expand to 48
        // bytes with empty key_info || I2OSP(48, 2).
        let prk = hmac_sha256(&salt, &[ikm, &[0]]);
        let t1 = hmac_sha256(&prk, &[&[0, 48], &[1]]);
        let t2 = hmac_sha256(&prk, &[&t1, &[0, 48], &[2]]);
        let mut okm = [0u8; 48];
        okm[..32].copy_from_slice(&t1);
        okm[32..].copy_from_slice(&t2[..16]);
        // OS2IP(OKM) mod r: big-endian 48 bytes as a little-endian wide
        // integer.
        let mut wide = [0u8; 64];
        for (i, b) in okm.iter().rev().enumerate() {
            wide[i] = *b;
        }
        let sk = Scalar::from_bytes_wide(&wide);
        if sk != Scalar::zero() {
            return Ok(sk);
        }
        salt = Sha256::digest(salt).into();
    }
}

/// Secret key as Kerrigan Core prints it (`bls generate`): 32 bytes,
/// big-endian, hex.
pub fn bls_secret_hex(sk: &Scalar) -> String {
    let mut b = sk.to_bytes();
    b.reverse();
    hex::encode(b)
}

pub fn parse_bls_secret(s: &str) -> Result<Scalar, Error> {
    let mut b: [u8; 32] = hex::decode(s.trim())
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or("An operator secret key is 64 hex characters")?;
    b.reverse();
    Option::<Scalar>::from(Scalar::from_bytes(&b))
        .filter(|s| *s != Scalar::zero())
        .ok_or_else(|| "Invalid operator secret key".into())
}

/// Public key (48 bytes, compressed G1, basic scheme serialisation).
pub fn bls_public(sk: &Scalar) -> [u8; 48] {
    G1Affine::from(G1Projective::generator() * sk).to_compressed()
}

pub fn parse_bls_public(s: &str) -> Result<[u8; 48], Error> {
    let b: [u8; 48] = hex::decode(s.trim())
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or("An operator public key is 96 hex characters")?;
    let p = Option::<G1Affine>::from(G1Affine::from_compressed(&b)).ok_or("Invalid operator public key")?;
    if bool::from(p.is_identity()) {
        return Err("Invalid operator public key".into());
    }
    Ok(b)
}

fn hash_to_g2(msg: &[u8]) -> G2Projective {
    <G2Projective as HashToCurve<ExpandMsgXmd<sha2_10::Sha256>>>::hash_to_curve([msg], BLS_DST)
}

/// Basic scheme signature (96 bytes, compressed G2).
pub fn bls_sign(sk: &Scalar, msg: &[u8]) -> [u8; 96] {
    G2Affine::from(hash_to_g2(msg) * sk).to_compressed()
}

#[cfg(test)]
pub fn bls_verify(pk: &[u8; 48], msg: &[u8], sig: &[u8; 96]) -> bool {
    let (Some(pk), Some(sig)) = (
        Option::<G1Affine>::from(G1Affine::from_compressed(pk)),
        Option::<G2Affine>::from(G2Affine::from_compressed(sig)),
    ) else {
        return false;
    };
    pairing(&pk, &G2Affine::from(hash_to_g2(msg))) == pairing(&G1Affine::generator(), &sig)
}

// ---------------------------------------------------------------------------
// ECDSA compact signatures (`CKey::SignCompact`)

/// 65 bytes: header (27 + recovery id + 4 for a compressed key), r, s.
pub fn sign_compact(key: &SecretKey, hash: [u8; 32]) -> [u8; 65] {
    let sig = RecoverableSignature::sign_ecdsa_recoverable(Message::from_digest(hash), key);
    let (recid, rs) = sig.serialize_compact();
    let mut out = [0u8; 65];
    out[0] = 27 + 4 + u8::from(recid);
    out[1..].copy_from_slice(&rs);
    out
}

/// Hash of a signed message (`CMessageSigner`): sha256d of the magic and
/// the message, each length-prefixed.
pub fn message_hash(message: &str) -> [u8; 32] {
    let mut s = Vec::new();
    write_bytes(&mut s, MESSAGE_MAGIC.as_bytes());
    write_bytes(&mut s, message.as_bytes());
    sha256d(&s)
}

pub fn parse_secret_key(s: &str) -> Result<SecretKey, Error> {
    let b: [u8; 32] = hex::decode(s.trim()).ok().and_then(|b| b.try_into().ok()).ok_or("Invalid private key")?;
    SecretKey::from_secret_bytes(b).map_err(|_| "Invalid private key".into())
}

// ---------------------------------------------------------------------------
// Addresses and services

fn base58_address(prefix: u8, hash: &[u8]) -> String {
    bs58::encode([&[prefix][..], hash].concat()).with_check().into_string()
}

/// Key id (hash160) of a P2PKH address.
fn key_id(address: &str, network: Network, what: &str) -> Result<[u8; 20], Error> {
    let script = transparent_script(address, network).map_err(|_| format!("Invalid {what} address"))?;
    if script.len() != 25 || script[0] != 0x76 {
        return Err(format!("The {what} address must be a regular (P2PKH) address"));
    }
    Ok(script[3..23].try_into().expect("20 bytes"))
}

/// `EncodeDestination` of a payout script (P2PKH or P2SH).
fn script_address(script: &[u8], network: Network) -> String {
    if script.len() == 25 && script[0] == 0x76 {
        base58_address(network.p2pkh_prefix(), &script[3..23])
    } else if script.len() == 23 && script[0] == 0xa9 {
        base58_address(network.p2sh_prefix(), &script[2..22])
    } else {
        hex::encode(script)
    }
}

/// Default P2P port of a network (`nDefaultPort`).
fn default_port(network: Network) -> u16 {
    match network {
        Network::Main => 7120,
        Network::Test => 17120,
        Network::Regtest => 27120,
    }
}

/// Default Platform ports of a network, the placeholders BroodNodes
/// register with.
fn platform_ports(network: Network) -> (u16, u16) {
    match network {
        Network::Main => (7121, 7122),
        Network::Test => (17121, 17122),
        Network::Regtest => (27121, 27122),
    }
}

/// A `CService` (16-byte IPv6 or IPv4-mapped address, big-endian port);
/// all zeros when `service` is empty (no server yet).
fn service_bytes(service: &str, network: Network) -> Result<[u8; 18], Error> {
    let mut out = [0u8; 18];
    let s = service.trim();
    if s.is_empty() {
        return Ok(out);
    }
    let addr: SocketAddr = s
        .parse()
        .or_else(|_| s.parse::<IpAddr>().map(|ip| SocketAddr::new(ip, default_port(network))))
        .map_err(|_| format!("Invalid server address: {s}"))?;
    let ip = match addr.ip() {
        IpAddr::V4(v4) => v4.to_ipv6_mapped().octets(),
        IpAddr::V6(v6) => v6.octets(),
    };
    // As Core checks it: mainnet masternodes use the mainnet port, others
    // never do.
    let main_port = default_port(Network::Main);
    if (network == Network::Main) != (addr.port() == main_port) {
        return Err(if network == Network::Main {
            format!("Mainnet masternodes must use port {main_port}")
        } else {
            format!("Port {main_port} is for mainnet masternodes only")
        });
    }
    out[..16].copy_from_slice(&ip);
    out[16..].copy_from_slice(&addr.port().to_be_bytes());
    Ok(out)
}

fn parse_hash(s: &str, what: &str) -> Result<[u8; 32], Error> {
    let mut b: [u8; 32] =
        hex::decode(s.trim()).ok().and_then(|b| b.try_into().ok()).ok_or(format!("Invalid {what}"))?;
    b.reverse();
    Ok(b)
}

// ---------------------------------------------------------------------------
// Payloads

/// Masternode type (`MnType`): 0 regular, 1 BroodNode (Evo).
const MN_TYPE_EVO: u16 = 1;

struct Platform {
    node_id: [u8; 20],
    p2p_port: u16,
    http_port: u16,
}

impl Platform {
    /// Placeholder Platform fields for a BroodNode: Kerrigan has no
    /// Platform, but Core requires a unique node id and the network's
    /// default ports. The id is derived from the operator key, which is
    /// unique too.
    fn for_operator(operator: &[u8; 48], network: Network) -> Self {
        let node_id: [u8; 20] = ripemd::Ripemd160::digest(Sha256::digest(operator)).into();
        let (p2p_port, http_port) = platform_ports(network);
        Self { node_id, p2p_port, http_port }
    }

    fn write(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.node_id);
        out.extend_from_slice(&self.p2p_port.to_le_bytes());
        out.extend_from_slice(&self.http_port.to_le_bytes());
    }
}

/// `CalcTxInputsHash`: sha256d of the inputs' outpoints.
fn inputs_hash(vin: &[TxIn]) -> [u8; 32] {
    let mut s = Vec::with_capacity(vin.len() * 36);
    for i in vin {
        s.extend_from_slice(&i.prev_txid);
        s.extend_from_slice(&i.prev_vout.to_le_bytes());
    }
    sha256d(&s)
}

/// How a payload is signed once the inputs (and so the inputs hash) are
/// known.
enum PayloadSigner {
    /// ProRegTx with an external collateral: the collateral key signs
    /// `MakeSignString()` as a message.
    Collateral { key: SecretKey, payout: String, reward: u16, owner: String, voting: String },
    /// ProUpRegTx: the owner key signs the payload hash.
    Owner(SecretKey),
    /// ProUpServTx / ProUpRevTx: the operator key (BLS) signs the payload
    /// hash.
    Operator(Scalar),
}

/// A provider payload: its bytes up to (not including) the signature,
/// given the inputs hash.
type PayloadBody = Box<dyn Fn(&[u8; 32]) -> Vec<u8>>;

fn signed_payload(body: &PayloadBody, signer: &PayloadSigner, inputs: &[u8; 32]) -> Vec<u8> {
    let mut payload = body(inputs);
    // `SerializeHash(proTx)` leaves the signature out.
    let hash = sha256d(&payload);
    match signer {
        PayloadSigner::Collateral { key, payout, reward, owner, voting } => {
            let message = format!("{payout}|{reward}|{owner}|{voting}|{}", display_hash(&hash));
            write_bytes(&mut payload, &sign_compact(key, message_hash(&message)));
        }
        PayloadSigner::Owner(key) => write_bytes(&mut payload, &sign_compact(key, hash)),
        PayloadSigner::Operator(sk) => payload.extend_from_slice(&bls_sign(sk, &hash)),
    }
    payload
}

fn signature_size(signer: &PayloadSigner) -> usize {
    match signer {
        PayloadSigner::Collateral { .. } | PayloadSigner::Owner(_) => 66,
        PayloadSigner::Operator(_) => 96,
    }
}

// ---------------------------------------------------------------------------
// Building

#[derive(Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum ProTxKind {
    /// ProRegTx with an external collateral (an output of the wallet).
    Register {
        #[serde(default)]
        evo: bool,
        collateral_txid: String,
        collateral_vout: u32,
        /// Private key of the collateral's address, hex.
        collateral_key: String,
        /// `ip:port`, or empty to register without a server.
        #[serde(default)]
        service: String,
        owner_address: String,
        voting_address: String,
        operator_public_key: String,
        payout_address: String,
        /// Operator's share of the rewards, in hundredths of a percent.
        #[serde(default)]
        operator_reward: u16,
    },
    /// ProUpServTx: set the masternode's server (signed by the operator).
    UpdateService {
        #[serde(default)]
        evo: bool,
        pro_tx_hash: String,
        service: String,
        operator_secret: String,
        /// Where the operator's share goes, if it has one.
        #[serde(default)]
        operator_payout_address: String,
    },
    /// ProUpRegTx: new operator key, voting address or payout address
    /// (signed by the owner).
    UpdateRegistrar {
        pro_tx_hash: String,
        operator_public_key: String,
        voting_address: String,
        payout_address: String,
        owner_key: String,
    },
    /// ProUpRevTx: the operator stops serving (signed by the operator).
    Revoke {
        pro_tx_hash: String,
        operator_secret: String,
        #[serde(default)]
        reason: u16,
    },
}

#[derive(Deserialize)]
pub struct JSProTxOptions {
    #[serde(flatten)]
    pub kind: ProTxKind,
    /// Transparent coins paying the fee.
    pub utxos: Vec<Utxo>,
    pub change_address: String,
    pub network: Network,
}

#[derive(Serialize)]
pub struct JSProTx {
    pub txid: String,
    pub txhex: String,
    /// Spent UTXOs, "txid,vout".
    pub nullifiers: Vec<String>,
    pub fee: u64,
    /// The payload as Kerrigan Core decodes it, for display: e.g. the
    /// operator public key registered.
    pub payload_hash: String,
}

fn build_payload(kind: &ProTxKind, network: Network) -> Result<(u16, PayloadBody, PayloadSigner), Error> {
    match kind {
        ProTxKind::Register {
            evo,
            collateral_txid,
            collateral_vout,
            collateral_key,
            service,
            owner_address,
            voting_address,
            operator_public_key,
            payout_address,
            operator_reward,
        } => {
            if *operator_reward > 10_000 {
                return Err("The operator reward is at most 100%".into());
            }
            let collateral = parse_hash(collateral_txid, "collateral transaction")?;
            let key = parse_secret_key(collateral_key)?;
            let service = service_bytes(service, network)?;
            let owner = key_id(owner_address, network, "owner")?;
            let voting = key_id(voting_address, network, "voting")?;
            let operator = parse_bls_public(operator_public_key)?;
            let payout = transparent_script(payout_address, network).map_err(|_| "Invalid payout address")?;
            if payout.get(3..23) == Some(&owner[..]) || payout.get(3..23) == Some(&voting[..]) {
                return Err("The payout address must differ from the owner and voting addresses".into());
            }
            let platform = evo.then(|| Platform::for_operator(&operator, network));
            let (vout, reward, mn_type) = (*collateral_vout, *operator_reward, u16::from(*evo) * MN_TYPE_EVO);
            let payout_script = payout.clone();
            let body: PayloadBody = Box::new(move |inputs| {
                let mut p = Vec::new();
                p.extend_from_slice(&PROTX_VERSION.to_le_bytes());
                p.extend_from_slice(&mn_type.to_le_bytes());
                p.extend_from_slice(&0u16.to_le_bytes()); // mode
                p.extend_from_slice(&collateral);
                p.extend_from_slice(&vout.to_le_bytes());
                p.extend_from_slice(&service);
                p.extend_from_slice(&owner);
                p.extend_from_slice(&operator);
                p.extend_from_slice(&voting);
                p.extend_from_slice(&reward.to_le_bytes());
                write_bytes(&mut p, &payout_script);
                p.extend_from_slice(inputs);
                if let Some(platform) = &platform {
                    platform.write(&mut p);
                }
                p
            });
            let signer = PayloadSigner::Collateral {
                key,
                payout: script_address(&payout, network),
                reward,
                owner: base58_address(network.p2pkh_prefix(), &owner),
                voting: base58_address(network.p2pkh_prefix(), &voting),
            };
            Ok((TX_PROVIDER_REGISTER, body, signer))
        }
        ProTxKind::UpdateService { evo, pro_tx_hash, service, operator_secret, operator_payout_address } => {
            let pro_tx = parse_hash(pro_tx_hash, "masternode registration")?;
            if service.trim().is_empty() {
                return Err("Enter the server's address".into());
            }
            let service = service_bytes(service, network)?;
            let sk = parse_bls_secret(operator_secret)?;
            let operator_payout = if operator_payout_address.is_empty() {
                Vec::new()
            } else {
                transparent_script(operator_payout_address, network).map_err(|_| "Invalid operator payout address")?
            };
            let platform = evo.then(|| Platform::for_operator(&bls_public(&sk), network));
            let mn_type = u16::from(*evo) * MN_TYPE_EVO;
            let body: PayloadBody = Box::new(move |inputs| {
                let mut p = Vec::new();
                p.extend_from_slice(&PROTX_VERSION.to_le_bytes());
                p.extend_from_slice(&mn_type.to_le_bytes());
                p.extend_from_slice(&pro_tx);
                p.extend_from_slice(&service);
                write_bytes(&mut p, &operator_payout);
                p.extend_from_slice(inputs);
                if let Some(platform) = &platform {
                    platform.write(&mut p);
                }
                p
            });
            Ok((TX_PROVIDER_UPDATE_SERVICE, body, PayloadSigner::Operator(sk)))
        }
        ProTxKind::UpdateRegistrar { pro_tx_hash, operator_public_key, voting_address, payout_address, owner_key } => {
            let pro_tx = parse_hash(pro_tx_hash, "masternode registration")?;
            let operator = parse_bls_public(operator_public_key)?;
            let voting = key_id(voting_address, network, "voting")?;
            let payout = transparent_script(payout_address, network).map_err(|_| "Invalid payout address")?;
            let key = parse_secret_key(owner_key)?;
            let body: PayloadBody = Box::new(move |inputs| {
                let mut p = Vec::new();
                p.extend_from_slice(&PROTX_VERSION.to_le_bytes());
                p.extend_from_slice(&pro_tx);
                p.extend_from_slice(&0u16.to_le_bytes()); // mode
                p.extend_from_slice(&operator);
                p.extend_from_slice(&voting);
                write_bytes(&mut p, &payout);
                p.extend_from_slice(inputs);
                p
            });
            Ok((TX_PROVIDER_UPDATE_REGISTRAR, body, PayloadSigner::Owner(key)))
        }
        ProTxKind::Revoke { pro_tx_hash, operator_secret, reason } => {
            let pro_tx = parse_hash(pro_tx_hash, "masternode registration")?;
            let sk = parse_bls_secret(operator_secret)?;
            if *reason > 3 {
                return Err("Invalid revocation reason".into());
            }
            let reason = *reason;
            let body: PayloadBody = Box::new(move |inputs| {
                let mut p = Vec::new();
                p.extend_from_slice(&PROTX_VERSION.to_le_bytes());
                p.extend_from_slice(&pro_tx);
                p.extend_from_slice(&reason.to_le_bytes());
                p.extend_from_slice(inputs);
                p
            });
            Ok((TX_PROVIDER_UPDATE_REVOKE, body, PayloadSigner::Operator(sk)))
        }
    }
}

/// Build and sign a provider transaction, paying the fee from `utxos`
/// (largest first) with change to `change_address`.
pub fn create_pro_tx(o: JSProTxOptions) -> Result<JSProTx, Error> {
    let (tx_type, body, signer) = build_payload(&o.kind, o.network)?;
    let change_script = transparent_script(&o.change_address, o.network).map_err(|_| "Invalid change address")?;
    if let ProTxKind::Register { collateral_txid, collateral_vout, .. } = &o.kind {
        if o.utxos.iter().any(|u| u.txid == *collateral_txid && u.vout == *collateral_vout) {
            return Err("The collateral can't pay the fee".into());
        }
    }

    let mut utxos = o.utxos;
    utxos.sort_by_key(|u| std::cmp::Reverse(u.amount));
    let payload_size = body(&[0; 32]).len() + signature_size(&signer) + 3;
    let fee_for = |inputs: usize, outputs: usize| {
        let size = TX_OVERHEAD + inputs * P2PKH_INPUT_SIZE + outputs * P2PKH_OUTPUT_SIZE + payload_size;
        (size as u64).max(MIN_FEE)
    };
    let mut used = Vec::new();
    let mut total = 0u64;
    for u in &utxos {
        used.push(u);
        total += u.amount;
        if total >= fee_for(used.len(), 1) + DUST {
            break;
        }
    }
    if used.is_empty() || total < fee_for(used.len(), 0) {
        return Err("Not enough transparent balance to pay the fee".into());
    }
    let mut fee = fee_for(used.len(), 1);
    let mut vout = Vec::new();
    if total >= fee + DUST {
        vout.push(TxOut { value: (total - fee) as i64, script: change_script });
    } else {
        fee = total;
    }

    let mut vin = Vec::new();
    let mut signers = Vec::new();
    for u in &used {
        vin.push(TxIn {
            prev_txid: parse_hash(&u.txid, "UTXO txid")?,
            prev_vout: u.vout,
            script_sig: Vec::new(),
            sequence: 0xffff_ffff,
        });
        signers.push(TransparentSigner::new(u)?);
    }
    let payload = signed_payload(&body, &signer, &inputs_hash(&vin));
    let payload_hash = display_hash(&sha256d(&body(&inputs_hash(&vin))));
    let mut tx = Transaction { version: 3, tx_type, vin, vout, lock_time: 0, extra_payload: payload };
    for (i, s) in signers.iter().enumerate() {
        let sighash = tx.transparent_sighash(i, s.script(), SIGHASH_ALL);
        tx.vin[i].script_sig = s.script_sig(sighash);
    }
    let bytes = tx.write();
    Ok(JSProTx {
        txid: display_hash(&sha256d(&bytes)),
        txhex: hex::encode(bytes),
        nullifiers: used.iter().map(|u| format!("{},{}", u.txid, u.vout)).collect(),
        fee,
        payload_hash,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keygen_round_trips() {
        let seed: Vec<u8> = (1..=32).collect();
        let sk = bls_keygen(&seed).unwrap();
        assert_eq!(bls_secret_hex(&sk).len(), 64);
        assert_eq!(parse_bls_secret(&bls_secret_hex(&sk)).unwrap(), sk);
    }

    #[test]
    fn bls_signatures_verify() {
        let sk = bls_keygen(&[7u8; 32]).unwrap();
        let pk = bls_public(&sk);
        let msg = sha256d(b"provider payload");
        let sig = bls_sign(&sk, &msg);
        assert!(bls_verify(&pk, &msg, &sig));
        assert!(!bls_verify(&pk, &sha256d(b"other"), &sig));
        assert_eq!(parse_bls_public(&hex::encode(pk)).unwrap(), pk);
    }

    #[test]
    fn services() {
        assert_eq!(service_bytes("", Network::Main).unwrap(), [0; 18]);
        let s = service_bytes("203.0.113.5", Network::Main).unwrap();
        assert_eq!(&s[10..16], &[0xff, 0xff, 203, 0, 113, 5]);
        assert_eq!(&s[16..], &7120u16.to_be_bytes());
        assert!(service_bytes("203.0.113.5:7121", Network::Main).is_err());
        assert!(service_bytes("127.0.0.1:7120", Network::Regtest).is_err());
        let v6 = service_bytes("[2001:db8::1]:27130", Network::Regtest).unwrap();
        assert_eq!(v6[0..2], [0x20, 0x01]);
    }

    #[test]
    fn compact_signatures_recover() {
        let key = SecretKey::from_secret_bytes([3u8; 32]).unwrap();
        let hash = message_hash("hello");
        let sig = sign_compact(&key, hash);
        assert!((31..=34).contains(&sig[0]));
        let recid = secp256k1::ecdsa::RecoveryId::try_from(i32::from(sig[0] - 31)).unwrap();
        let rec = RecoverableSignature::from_compact(&sig[1..], recid).unwrap();
        assert_eq!(rec.recover_ecdsa(Message::from_digest(hash)).unwrap(), key.public_key());
    }
}
