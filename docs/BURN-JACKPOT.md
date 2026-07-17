# Burn Jackpot — launch & ops runbook

`GitlawbBurnJackpot.sol` — weekly burn lottery on Base. Burn $GITLAWB through
the contract → tickets (1 wei = 1 ticket) → one Chainlink-VRF winner per epoch
takes 60% of the ETH pot, 40% rolls over. Tokens land at `0x…dEaD`, so
gitlawb.com/burners counts them like any other tribute. No owner withdrawal
exists: pot ETH can only exit through a drawn winner's `claim()`.

## Launch checklist (Base mainnet)

1. **VRF subscription** — at <https://vrf.chain.link> (Base): create a v2.5
   subscription, fund it with ETH (native payment; no LINK). ~0.01–0.02 ETH
   covers months of weekly draws. Note the subscription id.
2. **Deploy** — `VRF_SUB_ID=<id> forge script script/DeployBurnJackpot.s.sol
   --rpc-url https://mainnet.base.org --broadcast --private-key
   $DEPLOYER_PRIVATE_KEY --verify --etherscan-api-key $BASESCAN_API_KEY`
   (token/coordinator/key-hash default to Base mainnet values; 7-day epochs,
   60% winner split, 1,000 $GITLAWB min burn).
3. **Add consumer** — add the deployed address as a consumer on the VRF
   subscription. Draws revert without this.
4. **Seed** — `cast send <jackpot> "seedPot()" --value 1ether …`. Anyone can
   top the pot up later with a plain ETH transfer (emits `PotSeeded`).
5. **Keeper** — weekly cron calling `closeEpoch()`. Only strictly needed for
   zero-burn weeks: any `burnForTickets()` after the deadline closes the old
   epoch itself (the first burn of the new week triggers last week's draw).
6. **Dry run first** — same flow on Base Sepolia: coordinator
   `0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE`, key hash (30 gwei lane)
   `0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71`,
   `GITLAWB_TOKEN` pointed at a `GitlawbTestToken` deploy.

## Ops

- **Stuck draw** (`EpochClosed` seen but no `WinnerDrawn` — usually a drained
  VRF sub): top up the subscription, wait out `RETRY_DELAY` (4 h), then owner
  calls `retryDraw(epoch)`. The stale request id is invalidated; no
  double-draw is possible.
- **Pause** — `setPaused(true)` blocks new entries only. Pending draws and
  winner claims always work.
- **Tuning** — `setWinnerBps` (1–10000), `setMinBurn`, `setVrfConfig`
  (coordinator migration), `callbackGasLimit` default 300k is ample for the
  O(log n) winner search.
- **Monitoring** — index `BurnedForTickets`, `EpochClosed`, `WinnerDrawn`,
  `PrizeClaimed`, `PotSeeded`. `pot()` / `previewPrize()` / `epochEnds` /
  `ticketsOf(epoch, addr)` drive the UI.

## Compliance note

Burn-to-enter + chance + ETH prize reads as a lottery in most jurisdictions
(including PH). Before mainnet: counsel pass, ToS on the page, geo-gate the UI
where required, and keep site copy on "burner rewards" framing rather than
lottery/gambling language.
