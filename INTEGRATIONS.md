# Third-party integrations for Gitlawb

This document tracks external services compatible with Gitlawb's DID and bounty layers.

## Trust scoring

### MainStreet (Base mainnet)

[MainStreet](https://avisradar-production.up.railway.app/mainstreet.html) is a reputation oracle for onchain AI agents on Base. Returns BLOCK/CAUTION/PROCEED verdicts in <100ms with EIP-712 signatures.

Useful for Gitlawb in 4 places :

1. **Bounty escrow gate** (`GitlawbBounty.claim()`) — call `/preflight/{claimer}` before releasing escrow to avoid known-rug deployers.
2. **DID trust enrichment** (`GitlawbDIDRegistry`) — every DID anchored on-chain gets a `mainstreetScore` view function returning the wallet's current trust verdict.
3. **Node operator vetting** (`GitlawbNodeStaking`) — operators with red trust shield are flagged in the node UI before users delegate.
4. **Voter trust** (PIP governance) — proposals can require minimum MainStreet score from voters to participate.

**Endpoints (free, sub-100ms)** :

- `GET /api/agent/preflight/{address}` — BLOCK/CAUTION/PROCEED + reasoning
- `GET /api/agent/trust-shield/{address}` — green/yellow/red + 11 flags
- `GET /api/agent/token-info/{address}` — Virtuals + DexScreener + rug-risk for any Base ERC-20
- `GET /api/agent/wallet-cluster/{address}` — 1-hop spider web graph

**Discovery** :

- agent.json : https://avisradar-production.up.railway.app/.well-known/agent.json
- OpenAPI : https://avisradar-production.up.railway.app/api/agent/openapi.json
- ERC-8004 agentId : 53953 on Base
- Onchain verifier : 0x7397adb9713934c36d22aa54b4dbbcd70263592b
- MCP : `@raskhaaa/mainstreet-oracle`
- Operator : 0xAC3ca7c5d3cDD7702fd08F9C4C28dAA22296aDa9
