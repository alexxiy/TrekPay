//! Sapling key derivation and address encoding, as Kerrigan Core does it.
//!
//! - The spending key is ZIP 32 `m_Sapling/32'/coin_type'/account'` from
//!   the full BIP39 seed (Kerrigan Core `getNewSaplingAddress`), stored as
//!   the 169-byte serialised key in hex (what `z_exportkey` prints).
//! - The viewing key is the 128-byte diversifiable full viewing key
//!   (ak, nk, ovk, dk) in hex (what `z_exportviewingkey` prints).
//! - Payment addresses are Bech32m with the network's HRP.
use bech32::primitives::decode::CheckedHrpstring;
use bech32::{Bech32m, Hrp};
use sapling::zip32::{DiversifiableFullViewingKey, ExtendedSpendingKey};
use sapling::PaymentAddress;
use serde::{Deserialize, Serialize};
use zip32::{ChildIndex, DiversifierIndex};

use crate::network::Network;
use crate::Error;

const HARDENED: u32 = 0x8000_0000;

/// ZIP 32 account spending key for a BIP39 seed, hex encoded.
pub fn extsk_from_seed(seed: &[u8], coin_type: u32, account: u32) -> Result<String, Error> {
    if coin_type >= HARDENED || account >= HARDENED {
        return Err("Invalid coin type or account".into());
    }
    let master = ExtendedSpendingKey::master(seed).ok_or("Invalid seed")?;
    let path = [32 | HARDENED, coin_type | HARDENED, account | HARDENED]
        .map(|i| ChildIndex::from_index(i).expect("hardened index"));
    let xsk = ExtendedSpendingKey::from_path(&master, &path).ok_or("Key derivation failed")?;
    Ok(hex::encode(xsk.to_bytes()))
}

pub fn decode_extsk(enc: &str) -> Result<ExtendedSpendingKey, Error> {
    let bytes = hex::decode(enc.trim()).map_err(|_| "Spending key is not hex")?;
    ExtendedSpendingKey::from_bytes(&bytes).map_err(|_| "Invalid spending key".into())
}

/// Viewing key (diversifiable full viewing key) of a spending key, hex.
pub fn extfvk_from_extsk(enc_extsk: &str) -> Result<String, Error> {
    Ok(hex::encode(decode_extsk(enc_extsk)?.to_diversifiable_full_viewing_key().to_bytes()))
}

pub fn decode_dfvk(enc: &str) -> Result<DiversifiableFullViewingKey, Error> {
    let bytes: [u8; 128] = hex::decode(enc.trim())
        .map_err(|_| "Viewing key is not hex")?
        .try_into()
        .map_err(|_| "Viewing key must be 128 bytes")?;
    DiversifiableFullViewingKey::from_bytes(&bytes).ok_or_else(|| "Invalid viewing key".into())
}

pub fn encode_address(addr: &PaymentAddress, network: Network) -> String {
    let hrp = Hrp::parse(network.sapling_hrp()).expect("valid hrp");
    bech32::encode::<Bech32m>(hrp, &addr.to_bytes()).expect("address fits in Bech32m")
}

/// A Sapling payment address of `network`, or `None`.
pub fn decode_address(s: &str, network: Network) -> Option<PaymentAddress> {
    let checked = CheckedHrpstring::new::<Bech32m>(s).ok()?;
    if checked.hrp().as_str() != network.sapling_hrp() {
        return None;
    }
    let bytes: [u8; 43] = checked.byte_iter().collect::<Vec<u8>>().try_into().ok()?;
    PaymentAddress::from_bytes(&bytes)
}

pub fn is_valid_shield_address(s: &str, network: Network) -> bool {
    decode_address(s, network).is_some()
}

#[derive(Debug, Serialize, Deserialize)]
pub struct NewAddress {
    pub address: String,
    pub diversifier_index: Vec<u8>,
}

pub fn default_address(enc_dfvk: &str, network: Network) -> Result<NewAddress, Error> {
    let (index, addr) = decode_dfvk(enc_dfvk)?.default_address();
    Ok(NewAddress { address: encode_address(&addr, network), diversifier_index: index.as_bytes().to_vec() })
}

/// The wallet's change address: the default address of the internal
/// (ZIP 32 change) key, where Kerrigan Core also sees change.
pub fn change_address(enc_dfvk: &str, network: Network) -> Result<String, Error> {
    Ok(encode_address(&decode_dfvk(enc_dfvk)?.change_address().1, network))
}

/// The next valid payment address after `diversifier_index`.
pub fn next_address(enc_dfvk: &str, diversifier_index: &[u8], network: Network) -> Result<NewAddress, Error> {
    let dfvk = decode_dfvk(enc_dfvk)?;
    let bytes: [u8; 11] = diversifier_index.try_into().map_err(|_| "Invalid diversifier index")?;
    let mut index = DiversifierIndex::from(bytes);
    index.increment().map_err(|_| "No addresses left")?;
    let (index, addr) = dfvk.find_address(index).ok_or("No addresses left")?;
    Ok(NewAddress { address: encode_address(&addr, network), diversifier_index: index.as_bytes().to_vec() })
}

/// Where a payment goes: a shield address or a transparent output script.
pub enum Destination {
    Shield(PaymentAddress),
    Transparent(Vec<u8>),
}

/// Decode a shield (`ks1…`) or transparent (P2PKH / P2SH) address.
pub fn decode_destination(s: &str, network: Network) -> Result<Destination, Error> {
    if let Some(addr) = decode_address(s, network) {
        return Ok(Destination::Shield(addr));
    }
    transparent_script(s, network).map(Destination::Transparent)
}

/// Output script of a transparent address of `network`.
pub fn transparent_script(s: &str, network: Network) -> Result<Vec<u8>, Error> {
    let data = bs58::decode(s).with_check(None).into_vec().map_err(|_| format!("Invalid address: {s}"))?;
    if data.len() != 21 {
        return Err(format!("Invalid address: {s}"));
    }
    let hash = &data[1..];
    if data[0] == network.p2pkh_prefix() {
        Ok([&[0x76, 0xa9, 0x14][..], hash, &[0x88, 0xac]].concat())
    } else if data[0] == network.p2sh_prefix() {
        Ok([&[0xa9, 0x14][..], hash, &[0x87]].concat())
    } else {
        Err(format!("Address of another network: {s}"))
    }
}
