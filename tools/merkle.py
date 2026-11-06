#!/usr/bin/env python3
"""Build reproducible claim files with exact integers and Foundry's Ethereum Keccak.

Input is a JSON array of {"account": "0x...", "weight": "base-unit integer"}.
For holder rewards, provide the eligible snapshot balances as weights and --budget
equal to the epoch's allocationBudget. Exclusions must be applied before this tool.
Without --budget, leaves contain weights, as required by SimdAirdrop.
No network calls, packages, private keys or transaction submission.
"""

import argparse
import json
import re
import subprocess
import sys


UINT256_MAX = (1 << 256) - 1


def keccak(data):
    return bytes.fromhex(subprocess.check_output(
        ["cast", "keccak", "0x" + data.hex()], text=True
    ).strip()[2:])


def uint256(value):
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise ValueError("integers must be decimal strings or integers; floats are forbidden")
    text = str(value)
    if not re.fullmatch(r"[0-9]+", text):
        raise ValueError("integer must be unsigned decimal")
    result = int(text)
    if result > UINT256_MAX:
        raise ValueError("integer exceeds uint256")
    return result


def leaf(account, amount):
    return keccak(keccak(bytes.fromhex(account[2:]).rjust(32, b"\0") + amount.to_bytes(32, "big")))


def pair(a, b):
    return keccak(min(a, b) + max(a, b))


def build(rows, budget=None):
    if not isinstance(rows, list) or not rows:
        raise ValueError("input must be a nonempty array")
    weights = {}
    for row in rows:
        account = row["account"].lower()
        if not re.fullmatch(r"0x[0-9a-f]{40}", account) or int(account, 16) == 0:
            raise ValueError("invalid account")
        if account in weights:
            raise ValueError("duplicate account: " + account)
        weight = uint256(row["weight"])
        if weight == 0:
            raise ValueError("zero weight")
        weights[account] = weight
    total = sum(weights.values())
    if total > UINT256_MAX:
        raise ValueError("total weight exceeds uint256")
    budget = None if budget is None else uint256(budget)
    entries = []
    for account, weight in weights.items():
        amount = weight if budget is None else budget * weight // total
        if amount != 0:
            entries.append({"account": account, "weight": str(weight), "amount": str(amount),
                            "hash": leaf(account, amount)})
    entries.sort(key=lambda entry: entry["hash"])
    if not entries:
        return {"root": "0x" + "0" * 63 + "1", "totalWeight": str(total),
                "budget": str(budget), "allocated": "0", "claims": []}
    tree = [b""] * (2 * len(entries) - 1)
    for i, entry in enumerate(entries):
        tree[len(tree) - 1 - i] = entry["hash"]
    for i in range(len(tree) - len(entries) - 1, -1, -1):
        tree[i] = pair(tree[2 * i + 1], tree[2 * i + 2])
    for i, entry in enumerate(entries):
        at = len(tree) - 1 - i
        proof = []
        while at > 0:
            proof.append("0x" + tree[at + 1 if at % 2 else at - 1].hex())
            at = (at - 1) // 2
        entry["proof"] = proof
        del entry["hash"]
    result = {"root": "0x" + tree[0].hex(), "totalWeight": str(total),
              "allocated": str(sum(int(e["amount"]) for e in entries)), "claims": entries}
    if budget is not None:
        result["budget"] = str(budget)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="JSON array of accounts and snapshot weights")
    parser.add_argument("--budget", help="IMD allocationBudget in base units; omit for airdrop weight leaves")
    parser.add_argument("--expected-root", help="refuse a tree that does not reproduce this root")
    parser.add_argument("--expected-total", help="refuse a different total weight")
    parser.add_argument("--expected-count", type=int, help="refuse a different number of input wallets")
    args = parser.parse_args()
    with open(args.input, encoding="utf-8") as source:
        rows = json.load(source)
    result = build(rows, args.budget)
    if args.expected_root and result["root"] != args.expected_root.lower():
        raise ValueError("root mismatch")
    if args.expected_total and uint256(result["totalWeight"]) != uint256(args.expected_total):
        raise ValueError("total weight mismatch")
    if args.expected_count is not None and len(rows) != args.expected_count:
        raise ValueError("wallet count mismatch")
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
