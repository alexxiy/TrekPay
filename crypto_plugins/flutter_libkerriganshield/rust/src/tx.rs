//! Kerrigan transaction format (Dash-style special transactions).
//!
//! ```text
//! int16 nVersion | uint16 nType | vin | vout | uint32 nLockTime
//! | vExtraPayload (CompactSize length + bytes, when nVersion >= 3 and nType != 0)
//! ```
//!
//! A Sapling transaction has nVersion 3 and nType 10; its payload is a
//! `SaplingTxPayload` (Kerrigan Core `sapling/sapling_tx_payload.h`):
//!
//! ```text
//! uint16 nVersion (1) | spends | outputs | int64 valueBalance | bindingSig[64]
//! ```
use sha2::{Digest, Sha256};

use crate::Error;

pub const TX_VERSION_SPECIAL: i16 = 3;
pub const TX_TYPE_SAPLING: u16 = 10;
pub const SAPLING_PAYLOAD_VERSION: u16 = 1;
pub const SIGHASH_ALL: u32 = 1;

pub const SPEND_SIZE: usize = 384;
pub const OUTPUT_SIZE: usize = 948;
/// Kerrigan Core `MAX_SAPLING_TX_EXTRA_PAYLOAD` (whole tx size limit for type 10).
pub const MAX_SAPLING_TX_SIZE: usize = 150_000;
/// Consensus limit on spends and on outputs per transaction.
pub const MAX_SHIELDED_DESCRIPTIONS: usize = 500;

/// Bounds-checked reader over a byte slice.
pub struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    pub fn bytes(&mut self, n: usize) -> Result<&'a [u8], Error> {
        let end = self.pos.checked_add(n).filter(|&e| e <= self.data.len()).ok_or("Truncated data")?;
        let out = &self.data[self.pos..end];
        self.pos = end;
        Ok(out)
    }

    pub fn array<const N: usize>(&mut self) -> Result<[u8; N], Error> {
        Ok(self.bytes(N)?.try_into().expect("length checked"))
    }

    pub fn u8(&mut self) -> Result<u8, Error> {
        Ok(self.bytes(1)?[0])
    }

    pub fn u16(&mut self) -> Result<u16, Error> {
        Ok(u16::from_le_bytes(self.array()?))
    }

    pub fn u32(&mut self) -> Result<u32, Error> {
        Ok(u32::from_le_bytes(self.array()?))
    }

    pub fn i64(&mut self) -> Result<i64, Error> {
        Ok(i64::from_le_bytes(self.array()?))
    }

    /// Fail unless everything was read.
    pub fn finish(&self) -> Result<(), Error> {
        if self.pos == self.data.len() {
            Ok(())
        } else {
            Err("Unexpected trailing data".into())
        }
    }
}

pub fn read_compact_size(r: &mut Reader) -> Result<usize, Error> {
    let n = match r.u8()? {
        n @ 0..=252 => n as u64,
        253 => r.u16()? as u64,
        254 => r.u32()? as u64,
        _ => u64::from_le_bytes(r.array()?),
    };
    usize::try_from(n).ok().filter(|&n| n <= 0x0200_0000).ok_or_else(|| "Size too large".into())
}

pub fn write_compact_size(out: &mut Vec<u8>, n: usize) {
    if n < 253 {
        out.push(n as u8);
    } else if n <= 0xffff {
        out.push(253);
        out.extend_from_slice(&(n as u16).to_le_bytes());
    } else if n <= 0xffff_ffff {
        out.push(254);
        out.extend_from_slice(&(n as u32).to_le_bytes());
    } else {
        out.push(255);
        out.extend_from_slice(&(n as u64).to_le_bytes());
    }
}

pub fn write_bytes(out: &mut Vec<u8>, b: &[u8]) {
    write_compact_size(out, b.len());
    out.extend_from_slice(b);
}

pub fn sha256d(data: &[u8]) -> [u8; 32] {
    Sha256::digest(Sha256::digest(data)).into()
}

/// Display (RPC) form of a hash: byte-reversed hex.
pub fn display_hash(h: &[u8; 32]) -> String {
    let mut r = *h;
    r.reverse();
    hex::encode(r)
}

#[derive(Clone, Debug)]
pub struct TxIn {
    /// Previous txid, internal byte order.
    pub prev_txid: [u8; 32],
    pub prev_vout: u32,
    pub script_sig: Vec<u8>,
    pub sequence: u32,
}

#[derive(Clone, Debug)]
pub struct TxOut {
    pub value: i64,
    pub script: Vec<u8>,
}

impl TxOut {
    pub fn write(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.value.to_le_bytes());
        write_bytes(out, &self.script);
    }
}

#[derive(Clone, Debug)]
pub struct SpendDesc {
    pub cv: [u8; 32],
    pub anchor: [u8; 32],
    pub nullifier: [u8; 32],
    pub rk: [u8; 32],
    pub zkproof: [u8; 192],
    pub spend_auth_sig: [u8; 64],
}

#[derive(Clone, Debug)]
pub struct OutputDesc {
    pub cv: [u8; 32],
    pub cmu: [u8; 32],
    pub ephemeral_key: [u8; 32],
    pub enc_ciphertext: [u8; 580],
    pub out_ciphertext: [u8; 80],
    pub zkproof: [u8; 192],
}

#[derive(Clone, Debug)]
pub struct SaplingPayload {
    pub spends: Vec<SpendDesc>,
    pub outputs: Vec<OutputDesc>,
    pub value_balance: i64,
    pub binding_sig: [u8; 64],
}

impl SaplingPayload {
    fn read(data: &[u8]) -> Result<Self, Error> {
        let mut r = Reader::new(data);
        let version = r.u16()?;
        if version != SAPLING_PAYLOAD_VERSION {
            return Err(format!("Unknown Sapling payload version {version}"));
        }
        let n = read_compact_size(&mut r)?;
        if n > MAX_SHIELDED_DESCRIPTIONS {
            return Err("Too many spends".into());
        }
        let spends = (0..n)
            .map(|_| {
                Ok(SpendDesc {
                    cv: r.array()?,
                    anchor: r.array()?,
                    nullifier: r.array()?,
                    rk: r.array()?,
                    zkproof: r.array()?,
                    spend_auth_sig: r.array()?,
                })
            })
            .collect::<Result<Vec<_>, Error>>()?;
        let n = read_compact_size(&mut r)?;
        if n > MAX_SHIELDED_DESCRIPTIONS {
            return Err("Too many outputs".into());
        }
        let outputs = (0..n)
            .map(|_| {
                Ok(OutputDesc {
                    cv: r.array()?,
                    cmu: r.array()?,
                    ephemeral_key: r.array()?,
                    enc_ciphertext: r.array()?,
                    out_ciphertext: r.array()?,
                    zkproof: r.array()?,
                })
            })
            .collect::<Result<Vec<_>, Error>>()?;
        let value_balance = r.i64()?;
        let binding_sig = r.array()?;
        r.finish()?;
        Ok(Self { spends, outputs, value_balance, binding_sig })
    }

    fn write(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(
            2 + 18 + self.spends.len() * SPEND_SIZE + self.outputs.len() * OUTPUT_SIZE + 72,
        );
        out.extend_from_slice(&SAPLING_PAYLOAD_VERSION.to_le_bytes());
        write_compact_size(&mut out, self.spends.len());
        for s in &self.spends {
            for part in [&s.cv[..], &s.anchor, &s.nullifier, &s.rk, &s.zkproof, &s.spend_auth_sig] {
                out.extend_from_slice(part);
            }
        }
        write_compact_size(&mut out, self.outputs.len());
        for o in &self.outputs {
            for part in [&o.cv[..], &o.cmu, &o.ephemeral_key, &o.enc_ciphertext, &o.out_ciphertext, &o.zkproof] {
                out.extend_from_slice(part);
            }
        }
        out.extend_from_slice(&self.value_balance.to_le_bytes());
        out.extend_from_slice(&self.binding_sig);
        out
    }
}

#[derive(Clone, Debug)]
pub struct Transaction {
    pub version: i16,
    pub tx_type: u16,
    pub vin: Vec<TxIn>,
    pub vout: Vec<TxOut>,
    pub lock_time: u32,
    pub extra_payload: Vec<u8>,
}

impl Transaction {
    pub fn read(data: &[u8]) -> Result<Self, Error> {
        let mut r = Reader::new(data);
        let version = i16::from_le_bytes(r.array()?);
        let tx_type = r.u16()?;
        let n = read_compact_size(&mut r)?;
        let vin = (0..n)
            .map(|_| {
                Ok(TxIn {
                    prev_txid: r.array()?,
                    prev_vout: r.u32()?,
                    script_sig: {
                        let len = read_compact_size(&mut r)?;
                        r.bytes(len)?.to_vec()
                    },
                    sequence: r.u32()?,
                })
            })
            .collect::<Result<Vec<_>, Error>>()?;
        let n = read_compact_size(&mut r)?;
        let vout = (0..n)
            .map(|_| {
                Ok(TxOut {
                    value: r.i64()?,
                    script: {
                        let len = read_compact_size(&mut r)?;
                        r.bytes(len)?.to_vec()
                    },
                })
            })
            .collect::<Result<Vec<_>, Error>>()?;
        let lock_time = r.u32()?;
        let extra_payload = if version >= TX_VERSION_SPECIAL && tx_type != 0 {
            let len = read_compact_size(&mut r)?;
            r.bytes(len)?.to_vec()
        } else {
            Vec::new()
        };
        r.finish()?;
        Ok(Self { version, tx_type, vin, vout, lock_time, extra_payload })
    }

    fn write_header(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.version.to_le_bytes());
        out.extend_from_slice(&self.tx_type.to_le_bytes());
    }

    fn has_payload(&self) -> bool {
        self.version >= TX_VERSION_SPECIAL && self.tx_type != 0
    }

    pub fn write(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.write_header(&mut out);
        write_compact_size(&mut out, self.vin.len());
        for i in &self.vin {
            out.extend_from_slice(&i.prev_txid);
            out.extend_from_slice(&i.prev_vout.to_le_bytes());
            write_bytes(&mut out, &i.script_sig);
            out.extend_from_slice(&i.sequence.to_le_bytes());
        }
        write_compact_size(&mut out, self.vout.len());
        for o in &self.vout {
            o.write(&mut out);
        }
        out.extend_from_slice(&self.lock_time.to_le_bytes());
        if self.has_payload() {
            write_bytes(&mut out, &self.extra_payload);
        }
        out
    }

    /// The Sapling bundle of a type 10 transaction.
    pub fn sapling(&self) -> Result<Option<SaplingPayload>, Error> {
        if self.version >= TX_VERSION_SPECIAL && self.tx_type == TX_TYPE_SAPLING {
            SaplingPayload::read(&self.extra_payload).map(Some)
        } else {
            Ok(None)
        }
    }

    pub fn set_sapling(&mut self, payload: &SaplingPayload) {
        self.version = TX_VERSION_SPECIAL;
        self.tx_type = TX_TYPE_SAPLING;
        self.extra_payload = payload.write();
    }

    /// Legacy (pre-segwit) signature hash of input `n`, as Kerrigan Core's
    /// `SignatureHash` computes it: it also covers the extra payload, so
    /// transparent inputs are signed after the Sapling bundle is final.
    pub fn transparent_sighash(&self, n: usize, script_code: &[u8], hash_type: u32) -> [u8; 32] {
        let mut s = Vec::new();
        self.write_header(&mut s);
        write_compact_size(&mut s, self.vin.len());
        for (i, input) in self.vin.iter().enumerate() {
            s.extend_from_slice(&input.prev_txid);
            s.extend_from_slice(&input.prev_vout.to_le_bytes());
            write_bytes(&mut s, if i == n { script_code } else { &[] });
            s.extend_from_slice(&input.sequence.to_le_bytes());
        }
        write_compact_size(&mut s, self.vout.len());
        for o in &self.vout {
            o.write(&mut s);
        }
        s.extend_from_slice(&self.lock_time.to_le_bytes());
        if self.has_payload() {
            write_bytes(&mut s, &self.extra_payload);
        }
        s.extend_from_slice(&hash_type.to_le_bytes());
        sha256d(&s)
    }

    /// Kerrigan's Sapling signature hash (`ComputeSaplingSighash`), signed
    /// by the spend authorisations and the binding signature. It leaves
    /// out scriptSigs and the spend authorisation signatures.
    pub fn sapling_sighash(&self, spends: &[SpendDesc], outputs: &[OutputDesc], value_balance: i64) -> [u8; 32] {
        let mut s = Vec::new();
        s.extend_from_slice(&self.version.to_le_bytes());
        let mut prevouts = Vec::new();
        let mut sequences = Vec::new();
        for i in &self.vin {
            prevouts.extend_from_slice(&i.prev_txid);
            prevouts.extend_from_slice(&i.prev_vout.to_le_bytes());
            sequences.extend_from_slice(&i.sequence.to_le_bytes());
        }
        let mut outs = Vec::new();
        for o in &self.vout {
            o.write(&mut outs);
        }
        s.extend_from_slice(&sha256d(&prevouts));
        s.extend_from_slice(&sha256d(&sequences));
        s.extend_from_slice(&sha256d(&outs));
        s.extend_from_slice(&self.lock_time.to_le_bytes());
        s.extend_from_slice(&self.tx_type.to_le_bytes());
        s.extend_from_slice(&SAPLING_PAYLOAD_VERSION.to_le_bytes());
        let mut sp = Vec::with_capacity(spends.len() * 320);
        for d in spends {
            for part in [&d.cv[..], &d.anchor, &d.nullifier, &d.rk, &d.zkproof] {
                sp.extend_from_slice(part);
            }
        }
        s.extend_from_slice(&sha256d(&sp));
        let mut op = Vec::with_capacity(outputs.len() * OUTPUT_SIZE);
        for d in outputs {
            for part in [&d.cv[..], &d.cmu, &d.ephemeral_key, &d.enc_ciphertext, &d.out_ciphertext, &d.zkproof] {
                op.extend_from_slice(part);
            }
        }
        s.extend_from_slice(&sha256d(&op));
        s.extend_from_slice(&value_balance.to_le_bytes());
        sha256d(&s)
    }
}
