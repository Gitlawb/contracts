# GM-NET Standalone Bridge Usage

If the official Gitlawb integration is still pending, you can use the bridge contract directly to anchor your repository state.

## Contract Address (Base)
`0x...` (Deploying soon)

## Usage Example (ethers.js)

```javascript
const bridge = new ethers.Contract(BRIDGE_ADDRESS, BRIDGE_ABI, signer);

// 1. Prepare your GM-NET state root
const stateRoot = "0x..."; 

// 2. Anchor your repo state
const tx = await bridge.anchorRepoState("did:key:z6Mk...", stateRoot);
await tx.wait();

console.log("State anchored to GM-NET!");
```

## Verification
You can verify the latest anchored root for any DID:
```javascript
const root = await bridge.latestStateRoot(ethers.utils.id("did:key:z6Mk..."));
```
