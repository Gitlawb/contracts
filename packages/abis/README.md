# @gitlawb/contracts

TypeScript ABIs and deployed addresses for the [gitlawb protocol](https://github.com/gitlawb/gitlawb-contracts) on Base L2.

```
npm install @gitlawb/contracts
```

## Usage

```ts
import {
  NODE_STAKING_ABI,
  FEE_DISTRIBUTOR_ABI,
  addresses,
  BASE_SEPOLIA_ID,
  NODE_MIN_STAKE,
} from "@gitlawb/contracts";
import { createPublicClient, http } from "viem";
import { baseSepolia } from "viem/chains";

const client = createPublicClient({ chain: baseSepolia, transport: http() });
const { nodeStaking } = addresses[BASE_SEPOLIA_ID];

const stats = await client.readContract({
  address: nodeStaking,
  abi: NODE_STAKING_ABI,
  functionName: "getProtocolStats",
});
```

## Exports

### ABIs
- `ERC20_ABI` — minimal ERC20 (balanceOf, allowance, approve, transfer)
- `STAKING_ABI` — user staking (tier-weighted)
- `NODE_STAKING_ABI` — PoS for node operators
- `FEE_DISTRIBUTOR_ABI` — weekly reward split

### Addresses
- `addresses[BASE_SEPOLIA_ID]` — live on testnet
- `addresses[BASE_MAINNET_ID]` — placeholder until mainnet deploy
- `addressesFor(chainId)` — safe helper with fallback

### Constants
- `TIER_THRESHOLDS`, `TIER_MULTIPLIERS`, `TIER_NAMES` — staking tiers
- `NODE_MIN_STAKE`, `HEARTBEAT_WINDOW_SECONDS`, `INACTIVE_THRESHOLD_SECONDS`, `UNSTAKE_COOLDOWN_SECONDS`, `DISTRIBUTION_PERIOD_SECONDS`

## License

Apache-2.0
