# FADE v1

FADE is a custom Uniswap v4 launch prototype with a fixed one-billion-token supply, a one-sided permanently locked position, and an atomic minimum initial buy of `0.0006 ETH`.

Its native-side hook fee decays linearly from 3% to 1% over 24 hours. A fixed 10 bps of gross native swap volume accrues to the immutable Programmable treasury; the creator receives the remainder. The v4 LP fee and token transfer tax are both zero.

## Local verification

```sh
npm install --ignore-scripts
npm test
npm run fmt:check
npm run build
npm run manifest:verify
node "$PROGRAMMABLE_SKILL_ROOT/scripts/cli.mjs" open-world validate open-world-v2
```

The test suite covers all four swap quadrants, V4Quoter, Universal Router/V4Planner, Permit2 funding, multihop hook data, deadline/slippage/funding rejection, fuzzing, invariants, locked liquidity, and fee claims.

This repository and its Applicant package are **NOT_APPROVED**. They make no audit, deployment, Registry acceptance, production, or launch claim. The custom policy-neutral launch manifest remains subject to independent Programmable review.
