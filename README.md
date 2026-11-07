# SIMD TEST Vault

This is the application suite for **SIMD TEST 2 - DO NOT BUY**, a test of a SIMD relaunch on
Robinhood Chain (4663). It does not deploy a token or pool. Deploying `SIMDVault()` creates the
three linked child contracts. There is no owner, admin, upgrade, pause, withdrawal, arbitrary
execution, or factory requester-transfer function.

## Build and check

All Solidity dependencies are vendored as ordinary files. No package installation, network,
environment variables, FFI or filesystem cheatcodes are needed by the default test suite.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5865f61f0c0b5cd7860b4657c4402e8b18928a84d3873787dba88f874ffd4aea forge test
forge fmt --check
```

The compiler is pinned to Solidity **0.8.26**, with optimization, via-IR, Cancun, and
`bytecode_hash = "none"`. The default test chain is 4663. Tests use `vm.roll` and `vm.warp`,
never a mocked ArbSys. The one supplied signature vector uses its original Sepolia domain to
check interoperability, then checks that it cannot be replayed on 4663.

Live integration tests use the actual IMD, Intake, hook factory, PoolManager and existing pool
token. They skip if there is no real fork loaded; all behavioral tests run offline independently.
Run the integrations explicitly with:

```sh
forge test --match-contract RobinhoodForkTest --fork-url https://rpc.mainnet.chain.robinhood.com -vv
```

An archive RPC also permits `--fork-block-number`. The run reports its actual fork block.
Fork changes and impersonated calls exist only in the local simulation; tests never broadcast.
The HOOK factory's newest launch is still 3076, the previous test launch, which these contracts
refuse by design, so the flows after binding answer `positionOf(3077)` with `vm.mockCall` using
the real 3076 pool key; everything else (factory, Intake, IMD, pool token) is the live code.
See [verification notes](docs/VERIFICATION.md) for results and test scope.

## Deployment parameters

Deploy **only `SIMDVault`**, with no constructor arguments and no ETH. It deploys `SimdAirdrop`,
`JobsVault`, then `HolderRewards`, and exposes them as immutable `simdAirdrop()`, `jobsVault()`
and `holderRewards()` getters. Do not deploy additional copies of these children for this vault.
Constructors make no calls to pre-existing contracts, so deployment works on an empty chain.
No manifest or broadcast script is included; the deployment service handles that separately.

| Fixed dependency / destination | Address |
| --- | --- |
| IMD | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` |
| Intake v2 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| HOOK launch factory | `0xa25b02a1e93903b790e6aaf7da1b8b8d50294645` |
| Dev | `0xdfa1f1f6feaa04f7874eff0b7754b7ffaebd8bc0` |
| Marketing | `0xdfa1f1f6feaa04f7874eff0b7754b7ffaebd8bc0` |
| Oracle signer, from the supplied protocol reference | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| Burn destination | `0x000000000000000000000000000000000000dEaD` |

The PoolManager is read once from this factory's `poolManager()` when binding the token. The
live read returned `0x8366a39cc670b4001a1121b8f6a443a643e40951`. No Ethereum or other-chain
Uniswap address is assumed. All three action IDs are right-padded ASCII `bytes32`, not hashes.
Each payment reads the live `priceOf`, approves exactly that price, calls `request`, and clears
any remaining approval. A zero price means the action is unavailable. Prices are not configurable.

## After launch

1. Read the child addresses from the deployed vault. Fund the vault with enough IMD for
   `priceOf(bytes32("launch.open@launch-1"), IMD)`.
2. The fixed dev wallet calls `launch(bytes body)` once. The body must describe the **univ4_hook**
   launch of **SIMD TEST 2 - DO NOT BUY** on chain 4663, paired with **IMD**, with the launch
   remainder sent to the actual `simdAirdrop()` address. The dev supplies the complete approved
   launch JSON; token supply, pool economics and hook behavior belong to that separate launch.
   Preflight the body before spending the one successful request. The vault forwards bytes without
   interpreting JSON. An on-chain revert rolls back the one-shot flag; an off-chain rejection after
   payment does not restore it. The Intake records the vault as payer/requester.
3. After the pool exists, the dev calls `bindLaunch(uint64 launchNumber, address token)` once.
   The factory must report this vault as requester, the launch number must exceed 3076 (the
   previous test launch), the token must be a non-IMD ERC-20 currency in that pool and the pool's
   other currency must be IMD, so the vault can never bind a launch the airdrop would refuse.
   The child tokens become fixed in the same transaction. The token must expose `decimals()` for
   the jobs threshold.
4. Once the remainder has arrived, anyone calls `simdAirdrop.bind(launchNumber)`. The number must
   exceed 3076; the pair must contain IMD; the requester must be the vault; the vault's own binding
   must match; and the airdrop must already hold at least `TOTAL_WEIGHT` token base units.
   **Vault binding comes first.** This additional cross-check matters because the real factory
   lets a requester transfer its position to another address: transferring an unrelated position
   to the vault must not let someone front-run the airdrop's initialization.
5. Keepers call `distribute()` at least seven days after the previous successful distribution.
   The first call is allowed immediately after binding. Calls are permissionless and do not happen
   automatically. Monitor epoch/request events, retry unanswered oracle requests, publish claim
   proofs, roll expired epochs, and burn the remainder after the airdrop window closes.

No deployment parameter remains unspecified. The launch number/token are future results bound
from the real factory; there are no dummy addresses or token IDs in production configuration.

## Weekly distribution

`distribute()` first tries `claimFees(launchNumber)` with a 1,000,000 gas cap. A failed claim leaves
already-held assets available for distribution. Anyone may also call the factory directly: fees
still go to its recorded requester, the vault.

| Asset | Treatment |
| --- | --- |
| Whole IMD balance | 40% HolderRewards; 25.72% JobsVault; 17.14% dev; 17.14% marketing |
| Whole launched-token balance | Transfer to the fixed burn address |
| Whole native ETH balance | Try sending 100% to marketing with 50,000 gas |

Each IMD share is independently rounded down. At most three base units remain for a later week.
Dev and marketing are intentionally the same wallet and receive **two** independently rounded
shares. HolderRewards pays the oracle from its 40% share. A rejected or gas-consuming native
recipient leaves ETH in the vault for a future distribution, without reverting the split or burn.
No conversions occur. Unrelated assets have no rescue path. "Burn" means transfer to the stated
dead address, not a call that reduces ERC-20 `totalSupply`.

## Holder epochs and oracle protocol

Only the vault can notify a deposit. The contract measures its unreserved IMD balance rather than
trusting an amount argument. A deposit opens an epoch with a snapshot block and a 28-day window.
The snapshot is the L2 block `SNAPSHOT_DEPTH` (8) blocks before the deposit transaction's block:
the oracle plane refuses an absolute window whose last block is fewer than five deep when it
reads the ask, and a refused ask would spend the price without an answer. Robinhood snapshots
use `ArbSys(address(100)).arbBlockNumber()`; ordinary EVM runners without that precompile fall
back to `block.number`. Live fork tests check the L2 reader. A buyer after this snapshot gains no
entitlement to this epoch, even if they buy just before claiming. Holding before a known snapshot
is possible: this is a snapshot system, not a holding-duration rule.

The epoch immediately asks `oracle.request@oracle-1` for the root of **IMD allocations calculated
pro rata from snapshot token balances**. `claim(epoch, amount, proof)` takes the IMD allocation,
not the token balance. Each request pins the consumer address, epoch, token, absolute snapshot
block, eligible-holder definition, exclusions, exact net allocation budget and tree algorithm.
`oracleBody(epoch)` exposes the complete canonical JSON. The signed `questionHash` uses the
supplied IdentityMD `OracleQuestion` implementation.

Eligible weights are end-of-block raw `balanceOf` values plus the tokens the wallet has staked in
JobsVault (`stakeOf(wallet)` at that block), so staking for jobs costs no rewards. Pools, the
PoolManager, factory, all four suite contracts, the zero address and dead burn address are
excluded as holders. The denominator is the sum of eligible weights. Each allocation is `floor(allocationBudget * balance / denominator)`.
Leaves are `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`; trees use
OpenZeppelin StandardMerkleTree ordering and sorted-pair hashes. A root with no payable leaves
is `bytes32(uint256(1))`; its entire pot can eventually roll over.

The callback has the protocol's full 15-field attestation plus signature. It accepts only Intake,
a current request ID created here, the pinned question, chain and block window, a bytes32 answer,
and a current signature in this consumer's EIP-712 domain (`IdentityMD Oracle`, version `2`). It
requires at least 30 panel seats, quorum 20, and agreement at least the signed quorum. Each signed
oracle UUID is consumed once. The callback only verifies/stores and fits the 200,000 gas stipend.
There is no signer setter. These fixed dependencies follow the brief's immutable design even
though the general protocol examples use owner-settable configuration.

Oracle submission is isolated in a self-only call capped at 2,000,000 gas. Price lookup, approval,
payment and bookkeeping roll back together on failure. A pot at or below the oracle price is
not spent; it accumulates with the next vault deposit. Anyone can call `retryOracle(epoch)` one
day after an attempt while the epoch remains open and unanswered. This covers transaction
failure, refusal, disagreement, invalid/lost callbacks and no response. Each successful retry
spends a new live price from that epoch, reduces its net pot and invalidates the previous request.
A retry whose replacement request fails (Intake unavailable, or the pot no longer covers the
price) changes nothing: the pending request stays the epoch's request, its answer is still
accepted, and the epoch keeps its pot. The retry delay counts from the last attempt; the answer
freshness check counts from the last paid request (`askedAt`), so a failed retry does not refuse
an answer issued before it. There is no refund of successful Intake payments and no unsigned
failure callback needed.

The swarm must process the absolute deposit block after it is confirmed; the contract does not
silently substitute an earlier block. If admission races confirmation, the one-day retry keeps
the original snapshot. The question's wording screen returned no blockers; its record and the
screen's limits are in [oracle-wording-check.json](docs/oracle-wording-check.json).

## Claims, expiry and rollover accounting

Each holder claims only for themselves and once per epoch. The sum claimed cannot exceed the
net epoch pot **or** the fixed budget committed to its root, even if the oracle signs oversized
leaves. Claims close at `openedAt + 28 days`, independently of whether anyone has called rollover.

`rollover(epoch)` becomes available at that boundary, closes the old epoch and credits exactly
`pot - claimed` to the current epoch without transferring tokens or charging a fee. If the current
epoch is itself expired/closed, rollover opens a new one with a new snapshot; anyone may immediately
call `retryOracle` for its first request.

An existing signed/in-flight allocation cannot be expanded after some people have claimed.
Therefore additions to such a current epoch are recorded as `unallocated`, without changing
its existing leaf amounts. A retry before a root arrives includes those additions. Otherwise,
the next vault deposit moves them into the new epoch's budget and removes them from the old pot.
If there is no new deposit, expiry/rollover creates a fresh epoch where they can be allocated.
This preserves exact rollover credit, immutable entitlements, and eventual distribution of funds.
Rounding dust follows the same expiry path. `reserved` always equals the sum of unclaimed pots
of open epochs. Direct IMD donations are incorporated with the next vault notification.

## Jobs and airdrop

JobsVault pays `job.open@job-1` with no callback. A wallet holds launched tokens in the vault with
`stake(amount)` (after approving the vault) and is eligible while `stakeOf(wallet)` is at least
`1_000_000 * 10**token.decimals()` units; it may request one job per rolling 24 hours. A spot
wallet balance does not count: it can be lent within one transaction (a transfer chain or a
Uniswap v4 flash take), which would let one holding buy one job per hop. The stake that buys a
job is locked for 24 hours (`lockedUntil`), so one holding buys at most one job per day however
many wallets it passes through. `unstake(amount)` returns only the caller's own tokens once the
lock has passed; the vault's IMD leaves only as Intake job payments, so there is still no
withdraw. Staked tokens are credited to their stakers in the HolderRewards snapshot. Each request
consumes its daily slot and locks the stake even if the swarm later refuses the body. An
on-chain revert consumes neither payment, slot nor lock. Callers supply the whole body, limited
to 16 KiB; they are responsible for valid job JSON.

SimdAirdrop fixes these constants:

- Root: `0xe1fc34a5aee64c3cd01e62934929bc57511b5718c2f5ae80072ae25045e50cb4`.
- Total weight: `633028988023500000000000000` base units; 457 wallets.
- Leaf: `keccak256(bytes.concat(keccak256(abi.encode(account, weight))))`, sorted pairs.

Binding fixes `startBalance` and `claimEnd = bind timestamp + 30 days`. Each listed wallet claims
`floor(startBalance * weight / TOTAL_WEIGHT)` once for itself. Extra deposits do not change this
entitlement. At `claimEnd` claims are closed and anyone can call `burnUnclaimed()` to send every
remaining launched token, including later donations, to the burn address. Later donations can
be burned with another call. No list setter or alternative token-out path exists.

The repository contains a genuine listed-wallet proof in `test/fixtures/AirdropProof.sol`, recovered
from a successful Robinhood claim against this exact root. It is not a substitute list. Operators
must publish the complete original list/proofs for all 457 wallets. The supplied commitment is
sufficient for the on-chain contract; the full source list was not provided here.

## Proof tooling and operational assumptions

`tools/merkle.py` uses Python 3 and the installed Foundry `cast` binary, without network or external
Python packages. Given a JSON array of `{ "account": "0x…", "weight": "integer" }`, it builds
OpenZeppelin-compatible trees with exact integer arithmetic and outputs every proof. It refuses
duplicates, floats and invalid inputs. For rewards, input weights are eligible historical balances
after exclusions, and `--budget` is the epoch's committed `allocationBudget`:

```sh
python3 tools/merkle.py eligible-balances.json --budget 1000000000000000000 > claims.json
python3 tools/merkle.py original-weights.json \
  --expected-root 0xe1fc34a5aee64c3cd01e62934929bc57511b5718c2f5ae80072ae25045e50cb4 \
  --expected-total 633028988023500000000000000 --expected-count 457 > airdrop-proofs.json
```

The first command's budget is an example, not a deployment setting. Do not publish a claims file
until its root matches the accepted on-chain root. Enumerating holders, classifying pools,
verifying archival balances and publishing evidence/proofs are the swarm/operator responsibilities;
the contract verifies their signed commitment, not their off-chain computation.

IMD and the launched token are assumed to be ordinary, non-rebasing, non-taxed ERC-20s. SafeERC20
handles false/no-return behavior, but cannot make frozen or transfer-taxed assets obey these
economics. Native payouts and oracle/fee-collection failures are isolated; a failed ERC-20 split
or burn reverts the distribution atomically. All externally interacting value-moving functions
are reentrancy guarded. External protocol availability, signer integrity, correct snapshots and
proof availability remain trust assumptions. Fixed dependencies cannot be migrated by an admin.
Tests and the local review are not an independent security audit; the network's separate review
is still needed before release.

## Dependencies

OpenZeppelin Contracts v5.5.0 and forge-std v1.9.7 are vendored under `lib/`, with their licenses.
The canonical oracle attestation/question sources are copied from the task's pinned IdentityMD
reference. See [dependency provenance](docs/DEPENDENCIES.md).
