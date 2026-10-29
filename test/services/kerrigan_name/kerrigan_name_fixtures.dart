/// Made-up Kerrigan NameSpace records and the root their proofs fold to.
/// The tree holds five names, so every inner node has two children:
/// alice.krgn sits at depth 3, donate.krgn at depth 2. Hashing is KNS's
/// (`kns_core`, the same as PIVX.name's `pins_core`).
library;

const liveRoot =
    "b4cf1785a3ec0870c88b1d9454d6581991d10c80786f2c7599f01fc8d59a3406";

const liveTarget =
    "ks1l0c2g00waxlkde9l2s2jt86u7su0e0krndeh9deq42pwkz2hyqu0fm2t50lqv8q8sjv3xdgnzmw";

/// The key the "abandon … about" phrase makes (kerrigan_names_test.dart).
const liveOwnerKey =
    "93a5f261984931e0df5c7434b16d468efb1953098d3cad4fa1506b9e052e7fc7";

/// donate.krgn's address: well formed, and not alice.krgn's.
const otherShieldAddress =
    "ks1t4lur8z3v3a9wttwwfdwr8t4jdhu06njc66vv54kd7wyvx84ea863mwvwa6gddxsknqqkrz358d";

/// alice.krgn, with [changes] applied.
Map<String, dynamic> liveRecord([Map<String, Object?> changes = const {}]) => {
  "domain_name": "alice.krgn",
  "target_address": liveTarget,
  "owner_pubkey": liveOwnerKey,
  "price": 0,
  "nonce": 1786604913,
  "smt_root": liveRoot,
  "merkle_proof": [
    "7a82192137794bb5517a6555960e44c24297bc1b93db5190153539f8d724f8e2",
    "b425d835191c6b4f8335ad173b5c53ba24baca23e7efc5068ba91cd344ad4781",
    "65373c2edab2cca928c5d9df7bed8753ca4464c5b663b76859ad176cdfeac181",
  ],
  "proof_depth": 3,
  "proof_terminal": "Occupied",
  ...changes,
};

/// donate.krgn: listed for sale, so its price is not zero.
Map<String, dynamic> donateRecord() => {
  "domain_name": "donate.krgn",
  "target_address": otherShieldAddress,
  "owner_pubkey": liveOwnerKey,
  "price": 2499999000000,
  "nonce": 1786606068,
  "smt_root": liveRoot,
  "merkle_proof": [
    "fcf9c92765e251463c8539cb0b8e218d14414324a809d2f6161b2c167b41010d",
    "390eb687bda77e97ddb46252a7bc0ddf1d070b382eb549d2afa900646bd0d7dc",
  ],
  "proof_depth": 2,
  "proof_terminal": "Occupied",
};
