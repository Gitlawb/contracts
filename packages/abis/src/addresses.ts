export const BASE_MAINNET_ID = 8453;
export const BASE_SEPOLIA_ID = 84532;

export type ChainId = typeof BASE_MAINNET_ID | typeof BASE_SEPOLIA_ID;

export interface ContractAddresses {
  token: `0x${string}`;
  staking: `0x${string}`;
  nodeStaking: `0x${string}`;
  feeDistributor: `0x${string}`;
  bounty: `0x${string}`;
  didRegistry: `0x${string}`;
  nameRegistry: `0x${string}`;
  explorerBase: string;
}

export const addresses: Record<ChainId, ContractAddresses> = {
  [BASE_SEPOLIA_ID]: {
    token:          "0x3ec2454eb02127f8410cad049875158b210967c6",
    staking:        "0xbd55e18575b41944a2228c3c0c180de881162606",
    nodeStaking:    "0x39e4c5d5d95ff421ec7a5021dd2c8529b396d28a",
    feeDistributor: "0x4c97124213fb4f943dcfa815df2f4b3895da652a",
    bounty:         "0x8fc59d42b56fc153bcb9f871aae8e32bcf530789",
    didRegistry:    "0xddfad2d84cbff1c7078ee3f29b15614cba985c2e",
    nameRegistry:   "0x37a40b7bb2adc4566c46edd3285f365a9ff52c2c",
    explorerBase:   "https://sepolia.basescan.org",
  },
  [BASE_MAINNET_ID]: {
    token:          "0x5F980Dcfc4c0fa3911554cf5ab288ed0eb13DBa3",
    staking:        "0x0000000000000000000000000000000000000000",
    nodeStaking:    "0x0000000000000000000000000000000000000000",
    feeDistributor: "0x0000000000000000000000000000000000000000",
    bounty:         "0x0000000000000000000000000000000000000000",
    didRegistry:    "0x8046284116C5ac6724adbBf860feBeA85692d574",
    nameRegistry:   "0x73094B9DAb2421878A20Abed1497001fbD51302c",
    explorerBase:   "https://basescan.org",
  },
};

export function isSupportedChain(chainId: number | undefined): chainId is ChainId {
  return chainId === BASE_MAINNET_ID || chainId === BASE_SEPOLIA_ID;
}

export function addressesFor(chainId: number | undefined, fallback: ChainId = BASE_SEPOLIA_ID): ContractAddresses {
  return isSupportedChain(chainId) ? addresses[chainId] : addresses[fallback];
}

// Protocol constants
export const TIER_THRESHOLDS = {
  observer:  1_000n      * 10n ** 18n,
  curator:   10_000n     * 10n ** 18n,
  steward:   100_000n    * 10n ** 18n,
  validator: 1_000_000n  * 10n ** 18n,
} as const;

export const TIER_MULTIPLIERS: Record<number, number> = { 0: 0, 1: 1, 2: 2, 3: 4, 4: 8 };
export const TIER_NAMES: Record<number, string> = {
  0: "None", 1: "Observer", 2: "Curator", 3: "Steward", 4: "Validator",
};

export const NODE_MIN_STAKE = 10_000n * 10n ** 18n;
export const HEARTBEAT_WINDOW_SECONDS = 86_400;
export const INACTIVE_THRESHOLD_SECONDS = 3 * 86_400;
export const UNSTAKE_COOLDOWN_SECONDS = 7 * 86_400;
export const DISTRIBUTION_PERIOD_SECONDS = 7 * 86_400;
