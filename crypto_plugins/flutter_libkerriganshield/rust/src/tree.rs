//! Note commitment tree and witnesses, serialised in zcashd's format
//! (`write_commitment_tree` / `write_incremental_witness`), as hex.
//!
//! Tree:    Option<Node> left, Option<Node> right, Vec<Option<Node>> parents
//! Witness: tree, Vec<Node> filled, Option<tree> cursor
use incrementalmerkletree::frontier::CommitmentTree;
use incrementalmerkletree::witness::IncrementalWitness;
use sapling::Node;

use crate::tx::{read_compact_size, write_compact_size, Reader};
use crate::Error;

pub const DEPTH: u8 = sapling::NOTE_COMMITMENT_TREE_DEPTH;

pub type Tree = CommitmentTree<Node, DEPTH>;
pub type Witness = IncrementalWitness<Node, DEPTH>;

fn write_node(out: &mut Vec<u8>, node: &Node) {
    out.extend_from_slice(&node.to_bytes());
}

fn write_optional(out: &mut Vec<u8>, node: Option<&Node>) {
    match node {
        Some(n) => {
            out.push(1);
            write_node(out, n);
        }
        None => out.push(0),
    }
}

fn read_node(r: &mut Reader) -> Result<Node, Error> {
    Option::from(Node::from_bytes(r.array::<32>()?)).ok_or_else(|| "Invalid tree node".into())
}

fn read_optional(r: &mut Reader) -> Result<Option<Node>, Error> {
    match r.u8()? {
        0 => Ok(None),
        1 => read_node(r).map(Some),
        _ => Err("Invalid tree encoding".into()),
    }
}

fn write_tree_to(out: &mut Vec<u8>, tree: &Tree) {
    write_optional(out, tree.left().as_ref());
    write_optional(out, tree.right().as_ref());
    write_compact_size(out, tree.parents().len());
    for p in tree.parents() {
        write_optional(out, p.as_ref());
    }
}

fn read_tree_from(r: &mut Reader) -> Result<Tree, Error> {
    let left = read_optional(r)?;
    let right = read_optional(r)?;
    let n = read_compact_size(r)?;
    if n > DEPTH as usize {
        return Err("Invalid tree encoding".into());
    }
    let parents = (0..n).map(|_| read_optional(r)).collect::<Result<Vec<_>, _>>()?;
    CommitmentTree::from_parts(left, right, parents).map_err(|_| "Invalid tree encoding".into())
}

pub fn write_tree(tree: &Tree) -> String {
    let mut out = Vec::new();
    write_tree_to(&mut out, tree);
    hex::encode(out)
}

pub fn read_tree(enc: &str) -> Result<Tree, Error> {
    let bytes = hex::decode(enc).map_err(|_| "Tree is not hex")?;
    let mut r = Reader::new(&bytes);
    let tree = read_tree_from(&mut r)?;
    r.finish()?;
    Ok(tree)
}

pub fn write_witness(w: &Witness) -> String {
    let mut out = Vec::new();
    write_tree_to(&mut out, w.tree());
    write_compact_size(&mut out, w.filled().len());
    for n in w.filled() {
        write_node(&mut out, n);
    }
    match w.cursor() {
        Some(c) => {
            out.push(1);
            write_tree_to(&mut out, c);
        }
        None => out.push(0),
    }
    hex::encode(out)
}

pub fn read_witness(enc: &str) -> Result<Witness, Error> {
    let bytes = hex::decode(enc).map_err(|_| "Witness is not hex")?;
    let mut r = Reader::new(&bytes);
    let tree = read_tree_from(&mut r)?;
    let n = read_compact_size(&mut r)?;
    if n > DEPTH as usize {
        return Err("Invalid witness encoding".into());
    }
    let filled = (0..n).map(|_| read_node(&mut r)).collect::<Result<Vec<_>, _>>()?;
    let cursor = match r.u8()? {
        0 => None,
        1 => Some(read_tree_from(&mut r)?),
        _ => return Err("Invalid witness encoding".into()),
    };
    r.finish()?;
    IncrementalWitness::from_parts(tree, filled, cursor).ok_or_else(|| "Invalid witness".into())
}

/// Root of a serialised tree, as `finalsaplingroot` bytes (before the
/// display byte reversal).
pub fn sapling_root(enc: &str) -> Result<String, Error> {
    Ok(hex::encode(read_tree(enc)?.root().to_bytes()))
}
