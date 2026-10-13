//! Kerrigan network parameters (Kerrigan Core `src/chainparams.cpp`).
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Network {
    Main,
    Test,
    Regtest,
}

impl Network {
    /// Bech32m human-readable part of Sapling payment addresses.
    pub fn sapling_hrp(self) -> &'static str {
        match self {
            Network::Main => "ks",
            Network::Test => "ktestsapling",
            Network::Regtest => "kregsapling",
        }
    }

    /// Base58 version byte of P2PKH addresses.
    pub fn p2pkh_prefix(self) -> u8 {
        match self {
            Network::Main => 45,
            Network::Test => 107,
            Network::Regtest => 140,
        }
    }

    /// Base58 version byte of P2SH addresses.
    pub fn p2sh_prefix(self) -> u8 {
        match self {
            Network::Main => 16,
            Network::Test | Network::Regtest => 19,
        }
    }

    /// First block with Sapling (`consensus.SaplingHeight`).
    pub fn sapling_height(self) -> u32 {
        match self {
            Network::Main => 500,
            Network::Test => 100,
            Network::Regtest => 0,
        }
    }
}
