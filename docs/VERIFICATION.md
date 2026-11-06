# Verification and review notes

The implementation was checked locally on 2026-11-06. All checks use the repository's pinned
Solidity 0.8.26 configuration. The required fuzz seed is
`0x5865f61f0c0b5cd7860b4657c4402e8b18928a84d3873787dba88f874ffd4aea`.

## Final results

| Check | Result |
| --- | --- |
| `forge build --sizes` | Passed |
| `forge test` with the required seed | 60 passed; the offline fork suite skipped |
| `forge fmt --check` | Passed |
| Live `RobinhoodForkTest` | 5 passed at L2 block **107926631**, chain 4663 |
| `python3 -m unittest discover -s test -p 'test_*.py'` | 5 passed |
| Deployment bytecode inspection | All four application runtimes below EIP-170; initcode below EIP-3860; no library link placeholders or reachable forbidden escape opcodes |

| Application | Runtime bytes | Initcode bytes |
| --- | ---: | ---: |
| SIMDVault | 5,557 | 29,365 |
| HolderRewards | 15,904 | 17,340 |
| JobsVault | 2,514 | 2,703 |
| SimdAirdrop | 3,218 | 3,408 |

## Behavioral coverage

- Dev-only, one-shot launch/payment and binding; wrong requester/token; child-only initialization;
  exact approvals; rollback of failed launches; constructor deployment on an empty chain.
- Whole-balance splitting, independent rounding and conservation, first distribution at time zero,
  the exact seven-day boundary, fee-claim reverts/gas exhaustion, complete token burns.
- Native ETH paid during fee collection; successful payout, rejected payout, gas exhaustion,
  later retry and reentrancy from factory, token, Intake and marketing recipient.
- Jobs eligibility, six-decimal normalization, independent daily slots, exact daily boundary,
  changed holdings/prices, invalid body sizes, unavailable action and failed-payment rollback.
- Measured holder deposits, exact canonical JSON, exclusions and snapshot block, underfunded
  carry, unavailable price/request, one-day retry, retry costs isolated to the correct epoch,
  stale request invalidation and no approval residue.
- Canonical signed callbacks delivered under 200,000 gas; wrong sender/ID/question/chain/window,
  weak or impossible panels, expiration, future issuance, tampering, wrong answer type, replay
  and late callback rejection. Independent protocol digest, selector and question-hash vectors.
- Successful snapshot-derived pro-rata claims after holdings change, invalid proofs, double
  claims, correctly signed but oversized leaves, aggregate pot caps and failed-transfer rollback.
- Exact `pot - claimed` rollover, 28-day boundary, new epoch when current expires, pending and
  settled allocations, carry of additions to a fresh budget and subsequent successful claims.
- Airdrop binding threshold, IMD pair, requester, launch coherence, balance threshold, real proof,
  double/bad/unlisted claims, immutable start balance, final-second claims, closure at claimEnd,
  final burn including donations, repeat burn for later donations and transfer/reentrancy failure.

Three fuzz tests each run 1,000 inputs: IMD splits/dust, holder claim/rollover conservation and
airdrop payout/burn conservation. The stateful test uses 128 sequences of depth 48, mixing
deposits, donations, time, service failure, retries, signed answers, claims and rollovers. It
checks that open unclaimed pots equal reserves, reserves are covered, all deposited IMD is
accounted for as balance/fees/claims, and no approval remains. Handler reverts fail the invariant.

## Real-chain evidence

The fork suite uses chain 4663, the real IMD and Intake v2 and the **HOOK** factory. It exercises
the historical 3076 pool only as an integration fixture. Its requester is changed by impersonation
on the isolated fork, then the real factory's `claimFees` runs successfully. No protocol code is
mocked in this suite. Other tests verify real launch payment/payer records, oracle payment/callback
metadata, real-token jobs eligibility and rejection of unrelated/old launches.

Source RPC: `https://rpc.mainnet.chain.robinhood.com`. The supplied provider lacks older archival
state, so successful runs use a fresh fork; no historical replay or state mutation is sent to RPC.
The suite logs the L2 block and explicitly uses `vm.roll` for the Arbitrum harness. Default offline
tests skip the fork suite if live dependencies are absent.

The real airdrop proof is from Robinhood transaction
`0xc07c2b61799054ee0ca36b30cb2b2ddf08899bb589c78f4ab4658705100405ca`, read using
`eth_getTransactionByHash`. It claimed from prior test airdrop
`0x4f375b772f0668282f0d1aae573fcb601ea04772`. The fixture wallet's weight is
`1000000000000000000000000`; its nine proof elements reproduce exactly the new brief's immutable
root. The production contract's root is not replaced or made configurable for these tests.

IdentityMD's free oracle wording check returned HTTP 200 and `blockers: []`. The check is a
wording/admission preview, not a paid oracle run or an attestation; it does not establish actual
future snapshot correctness. See `oracle-wording-check.json` for the exact screen response.

## Local adversarial review

The review traced every value-out path and tested the important failure boundaries. Two design
details address concrete hazards:

1. The factory allows requester transfers. An unrelated launcher could otherwise transfer its
   role to the vault and fund the airdrop with another token before the intended binding. Requiring
   a matching completed vault binding removes that public initialization race.
2. Adding rollover funds to an already committed root must not change existing claim entitlements.
   The contract separates the fixed allocation budget from unallocated additions, then carries
   additions to a fresh request. Claims are capped by both the epoch pot and the root's budget.

The oracle signer/panel is trusted to compute honest allocations. Per-epoch caps contain an
oversized root but cannot distinguish a dishonest in-budget allocation. Proof publication and
holder/pool discovery are off-chain responsibilities. The airdrop's complete original list was
not supplied; its commitment is fixed and a genuine membership proof is verified.

No Slither/Mythril run or independent audit is claimed. The network's independent review remains
a release responsibility. No transactions were signed or broadcast to a real chain.
