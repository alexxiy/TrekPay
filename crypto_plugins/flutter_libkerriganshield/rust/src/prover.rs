//! Sapling proving parameters, loaded once from files the app downloaded.
//! Kerrigan uses the Zcash Sapling parameters.
use sapling::circuit::{OutputParameters, SpendParameters};
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

use crate::Error;

static PROVER: OnceLock<(SpendParameters, OutputParameters)> = OnceLock::new();

pub const SAPLING_OUTPUT_SHA256: &str = "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4";
pub const SAPLING_SPEND_SHA256: &str = "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13";

pub fn load_from_files(output_path: &str, spend_path: &str) -> Result<(), Error> {
    if PROVER.get().is_some() {
        return Ok(());
    }
    let output = std::fs::read(output_path).map_err(|e| format!("{output_path}: {e}"))?;
    let spend = std::fs::read(spend_path).map_err(|e| format!("{spend_path}: {e}"))?;
    if hex::encode(Sha256::digest(&output)) != SAPLING_OUTPUT_SHA256 {
        return Err("Sha256 does not match for sapling output".into());
    }
    if hex::encode(Sha256::digest(&spend)) != SAPLING_SPEND_SHA256 {
        return Err("Sha256 does not match for sapling spend".into());
    }
    let params = (
        SpendParameters::read(&spend[..], false).map_err(|e| e.to_string())?,
        OutputParameters::read(&output[..], false).map_err(|e| e.to_string())?,
    );
    let _ = PROVER.set(params);
    Ok(())
}

pub fn is_loaded() -> bool {
    PROVER.get().is_some()
}

pub fn get() -> Result<(&'static SpendParameters, &'static OutputParameters), Error> {
    let (s, o) = PROVER.get().ok_or("Sapling prover not loaded")?;
    Ok((s, o))
}
