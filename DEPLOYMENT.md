# Reproducible deployment plan

No deployment has been executed by this repository.

1. Run `scripts/bootstrap-deps.sh` and verify every dependency is at the commit in
   `dependencies/source-pins.json`.
2. Run `forge fmt --check`, `forge build --offline`, `forge test --offline`, the CI fuzz/invariant profile, and Slither.
3. Bind canonical Ethereum PoolManager and PositionManager addresses and verify their runtime hashes independently.
4. Deploy `FadeDecayFeeHookFactoryV1`.
5. Mine a CREATE2 salt for exactly the five declared hook permission bits and deploy `FadeDecayFeeHookV1` through the
   factory.
6. Deploy `LockedPositionFeeForwarderFactoryV1` bound to the canonical PositionManager.
7. Deploy `FadeLaunchV1` bound to those exact dependencies.
8. Record deployment transactions, runtime hashes, constructor arguments, compiler settings, source-verification
   results, and the exact repository commit/tree.
9. Repeat bytecode checks against Mainnet and configure the Programmable interface only for the exact reviewed release.

The deployer has no post-deployment role in the hook, launcher, token supply, fee schedule, recipients, or locked
position.
