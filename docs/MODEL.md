# FADE v1

FADE v1 is a complete Ethereum Uniswap v4 launch model with one intentional twist: its total ETH swap fee starts at
3.00%, decreases linearly over the first 24 hours, and then remains at 1.00%.

## Launch behavior

- The launcher creates a fixed-supply one-billion-token UERC20.
- The complete supply enters a one-sided Uniswap v4 position; no separate creator ETH liquidity deposit is required.
- The position NFT is sent to a forwarder with no operator and `type(uint256).max` timelock.
- The creator makes an atomic initial buy of at least `0.0006 ETH`; gas is separate.
- Name, symbol, description, website, image, and social metadata are launch inputs rather than hardcoded values.

## Fees

| Item | Behavior |
| --- | --- |
| Total swap fee | 3.00% at registration, linearly decaying to 1.00% after 24 hours |
| Programmable | fixed 0.10 percentage points of gross canonical ETH pool volume |
| Creator | total fee minus 0.10 percentage points, paid in native ETH |
| ERC20 transfer tax | none |
| Uniswap v4 LP fee | zero |
| Fee reinvestment | none; fees do not increase locked liquidity |

The creator recipient is the wallet that calls `launch`. Fees cannot be redirected by an administrator. The intended
launch wallet for this application is `0x2Bb333d48DFAF1596D9036671d2E43168994249E`.

## Current authority state

This repository is source and test evidence only. It is not an audit, approval, deployment, Registry entry, production
release, or authorization to launch. No Mainnet transaction has been signed or broadcast.

Read `SECURITY.md`, `ARCHITECTURE.md`, and `DEPLOYMENT.md` before review.
