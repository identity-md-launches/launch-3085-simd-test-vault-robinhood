# Dependency provenance

The project builds offline from files in this repository. There are no git submodules,
package-manager runtime dependencies, downloads during tests, or compiler binaries in the tree.

| Dependency | Pin | Upstream | Local files |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | `v5.5.0` | https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.5.0 | `lib/openzeppelin-contracts/contracts/` (the complete import closure used here), `LICENSE` |
| forge-std | `v1.9.7` | https://github.com/foundry-rs/forge-std/tree/v1.9.7 | `lib/forge-std/src/`, `LICENSE-APACHE`, `LICENSE-MIT` |
| IdentityMD oracle sources | Pinned task reference `0ec4d89a-4eee-4369-827d-a4f03feb151b:15` | Supplied `oracle-consumer/REFERENCE.md` | `src/oracle/OracleAttestation.sol`, `src/oracle/OracleQuestion.sol` |

OpenZeppelin and forge-std were downloaded as release source archives. Only ordinary files were
extracted, preserving upstream source and licenses. The vendored file SHA-256 manifest is
`dependencies.sha256.json`. The two MIT-licensed oracle source blocks were copied from the
provided reference; only formatting changes are applied. Their protocol signature and question
hash vectors are checked in `test/OracleConformance.t.sol`.

`tools/merkle.py` is project code. It needs Python 3's standard library and the Foundry `cast`
executable for Ethereum Keccak-256; it never substitutes NIST SHA3-256 and never uses the network.
