# Architecture decision

## Selected: minimum-correct v4 launch model

FADE uses the smallest architecture that preserves the requested market behavior:

1. `FadeLaunchV1` creates the token, registers and initializes the pool, places the complete token supply into the
   one-sided position, locks the position, and executes the initial buy atomically.
2. `FadeDecayFeeHookV1` applies the time-based ETH fee inside PoolManager callbacks and accounts separately for the
   immutable creator and Programmable recipients.
3. `LockedPositionFeeForwarderFactoryV1` creates the permanent position recipient.
4. `FadeDecayFeeHookFactoryV1` deploys the hook at an address whose permission bits match its callbacks.

## Compared alternatives

- `minimum-correct`: selected. One pool, one shared hook, one launcher, and no offchain executor or creator reward vault.
- `v4-native`: functionally identical for this intent; extra hook-owned liquidity or custom curves add risk without
  changing the requested one-sided launch.
- `hybrid`: rejected. An offchain fee scheduler would add availability, key, ordering, and configuration risks even
  though `block.timestamp` can deterministically select the fee inside the atomic swap.

There is no owner, proxy, pause, post-launch fee setter, supply mint, token seizure, liquidity withdrawal, keeper, or
offchain pricing dependency.
