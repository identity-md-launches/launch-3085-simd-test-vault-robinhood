"""Run with python3 -m unittest discover -s test -p 'test_*.py'."""

import importlib.util
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("merkle", ROOT / "tools/merkle.py")
merkle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(merkle)


class MerkleToolTest(unittest.TestCase):
    def test_ethereum_keccak_vector(self):
        self.assertEqual(merkle.keccak(b"").hex(),
                         "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

    def test_real_airdrop_proof_uses_same_leaf_and_pair_encoding(self):
        fixture = (ROOT / "test/fixtures/AirdropProof.sol").read_text()
        weight = int(re.search(r"WEIGHT = ([0-9]+)", fixture).group(1))
        siblings = re.findall(r"p\[\d+\] = (0x[0-9a-f]{64})", fixture)
        node = merkle.leaf("0xdfa1f1f6feaa04f7874eff0b7754b7ffaebd8bc0", weight)
        for sibling in siblings:
            node = merkle.pair(node, bytes.fromhex(sibling[2:]))
        self.assertEqual(node.hex(), "e1fc34a5aee64c3cd01e62934929bc57511b5718c2f5ae80072ae25045e50cb4")

    def test_non_power_of_two_tree_proofs_and_exact_pro_rata_rounding(self):
        rows = [{"account": "0x" + format(i, "040x"), "weight": str(i * i)} for i in range(1, 6)]
        output = merkle.build(rows, "1000000000000000003")
        total = sum(i * i for i in range(1, 6))
        allocated = 0
        for entry in output["claims"]:
            amount = int(entry["amount"])
            self.assertEqual(amount, 1000000000000000003 * int(entry["weight"]) // total)
            node = merkle.leaf(entry["account"], amount)
            for sibling in entry["proof"]:
                node = merkle.pair(node, bytes.fromhex(sibling[2:]))
            self.assertEqual("0x" + node.hex(), output["root"])
            allocated += amount
        self.assertLessEqual(1000000000000000003 - allocated, 4)
        self.assertEqual(merkle.build(list(reversed(rows)), "1000000000000000003"), output)

    def test_invalid_and_duplicate_inputs_are_refused(self):
        a = "0x" + "12" * 20
        for bad in [True, 1.5, "-1", "1.0", "1e18", 1 << 256]:
            with self.assertRaises(ValueError):
                merkle.build([{"account": a, "weight": bad}])
        for rows in [[], [{"account": a, "weight": "0"}],
                     [{"account": "0x" + "00" * 20, "weight": "1"}],
                     [{"account": a, "weight": "1"}, {"account": a, "weight": "2"}]]:
            with self.assertRaises(ValueError):
                merkle.build(rows)

    def test_zero_budget_matches_no_payable_leaf_convention(self):
        output = merkle.build([{"account": "0x" + "12" * 20, "weight": "1"}], 0)
        self.assertEqual(output["claims"], [])
        self.assertEqual(output["root"], "0x" + "0" * 63 + "1")


if __name__ == "__main__":
    unittest.main()
