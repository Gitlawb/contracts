# gitlawb-contracts

On-chain contracts for the gitlawb protocol — DID registry, name registry, bounty escrow, user staking, node operator staking (PoS), and the weekly fee distributor.

**Network:** Base L2 (mainnet) · Base Sepolia (testnet)

```
Apache-2.0 · fully open-source · 87 foundry tests
```

---

## Contracts

| Contract | Purpose |
|---|---|
| [`GitlawbDIDRegistry`](src/GitlawbDIDRegistry.sol) | On-chain anchor of `did:key:...` → DID document |
| [`GitlawbNameRegistry`](src/GitlawbNameRegistry.sol) | Human-readable names → DID (Base L2 ENS equivalent) |
| [`GitlawbBounty`](src/GitlawbBounty.sol) | ERC20 escrow for agent bounties, 5% protocol fee |
| [`GitlawbStaking`](src/GitlawbStaking.sol) | Tier-weighted passive staking (Observer 1x → Validator 8x) |
| [`GitlawbNodeStaking`](src/GitlawbNodeStaking.sol) | PoS for node operators — 10k min stake, 24h heartbeat, 3d inactive threshold |
| [`GitlawbFeeDistributor`](src/GitlawbFeeDistributor.sol) | Weekly permissionless split: **75% nodes · 24% users · 1% keeper** |

## Economics

All protocol fees (bounty 5%, optional node fees, manual deposits) land in `GitlawbFeeDistributor`. Once every 7 days, **anyone** can call `distribute()` to split the balance:

```
pot
├── 75% → node operator stakers (pro-rata by active stake)
├── 24% → user stakers (pro-rata by tier-weighted stake)
└──  1% → msg.sender (keeper reward — makes the call self-funding)
```

Full math + worked examples: [`docs/ECONOMICS.md`](docs/ECONOMICS.md).

## Running a node

If you want to stake and earn the node-operator share, see [`docs/RUN-A-NODE.md`](docs/RUN-A-NODE.md).

---

## Deployments

### Base Sepolia (testnet)

| Contract | Address |
|---|---|
| GitlawbTestToken (tGITLAWB) | `0x3ec2454eb02127f8410cad049875158b210967c6` |
| GitlawbDIDRegistry | `0xddfad2d84cbff1c7078ee3f29b15614cba985c2e` |
| GitlawbNameRegistry | `0x37a40b7bb2adc4566c46edd3285f365a9ff52c2c` |
| GitlawbStaking | `0xbd55e18575b41944a2228c3c0c180de881162606` |
| GitlawbNodeStaking | `0x39e4c5d5d95ff421ec7a5021dd2c8529b396d28a` |
| GitlawbFeeDistributor | `0x4c97124213fb4f943dcfa815df2f4b3895da652a` |
| GitlawbBounty | `0x8fc59d42b56fc153bcb9f871aae8e32bcf530789` |

### Base mainnet

| Contract | Address |
|---|---|
| $GITLAWB token | `0x5F980Dcfc4c0fa3911554cf5ab288ed0eb13DBa3` |
| GitlawbDIDRegistry | `0x8046284116C5ac6724adbBf860feBeA85692d574` |
| GitlawbNameRegistry | `0x73094B9DAb2421878A20Abed1497001fbD51302c` |
| GitlawbStaking | *TBD — deploy pending* |
| GitlawbNodeStaking | *TBD* |
| GitlawbFeeDistributor | *TBD* |
| GitlawbBounty | *TBD* |

---

## Development

```bash
# Install foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install dependencies (forge-std)
forge install

# Build
forge build

# Run tests (87 tests, should all pass)
forge test

# Coverage report
forge coverage

# Gas report
forge test --gas-report
```

### Deploy to Base Sepolia

```bash
# Testnet one-shot — deploys a mock token + all 6 contracts, wires them, mints 10M to deployer
forge script script/DeployTestnet.s.sol \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY
```

### Deploy to Base mainnet

```bash
export GITLAWB_TOKEN=0x5F980Dcfc4c0fa3911554cf5ab288ed0eb13DBa3
forge script script/Deploy.s.sol \
  --rpc-url https://mainnet.base.org \
  --broadcast \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY
```

---

## Audit

Internal review performed 2026-04-20. One MEDIUM finding (stranded-rewards bug in `_harvest` else-branch) — fixed, two regression tests added.

External audit: pending before mainnet deploy.

---

## TypeScript / JS bindings

ABIs + addresses are exported from [`packages/abis`](./packages/abis) as `@gitlawb/contracts` (npm, publish pending). Consumable directly:

```ts
import { NODE_STAKING_ABI, addresses } from "@gitlawb/contracts";
import { baseSepolia } from "wagmi/chains";

const nodeStaking = addresses[baseSepolia.id].nodeStaking;
```

---

## License

Apache-2.0 — see [LICENSE](LICENSE).

Contracts are open-source and permissionless. Fork, audit, deploy your own. Attribution appreciated but not required.

---

[gitlawb.com](https://gitlawb.com) · [@gitlawb](https://x.com/gitlawb)
