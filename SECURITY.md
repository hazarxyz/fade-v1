# Security properties and limitations

## Fixed properties

- Ethereum Mainnet only for a production release.
- Fixed supply: `1,000,000,000 * 10^18`; no mint function is exposed by the launched token.
- One-sided position recipient: zero operator, maximum timelock, no configured liquidity-removal path.
- LP fee: zero. ERC20 transfer tax: zero.
- Total ETH swap fee: 300 bps at registration, monotonically decreasing to 100 bps at 24 hours.
- Programmable share: exactly 10 bps of gross native pool volume to
  `0x4957f49620AFf3Adbbe8195a4f633E49cc93376c`.
- Creator share: applied total fee minus 10 bps, claimable only to the immutable launch wallet.

## Hook permissions

All fourteen permissions begin disabled. FADE enables only:

- `beforeInitialize`
- `beforeSwap`
- `afterSwap`
- `beforeSwapReturnDelta`
- `afterSwapReturnDelta`

Return-delta permissions are high risk. FADE uses them only to take the bounded native fee; it never claims to execute
the underlying trade. The exact-input/exact-output and buy/sell paths are tested separately. Native-specified partial
fills revert when the observed pool delta does not match the requested amount after fee arithmetic. A reverted swap
leaves no fee accrual.

All callbacks inherit PoolManager caller verification. Pool registration verifies pool shape, the hook address, zero
LP fee, tick spacing, native/token currency order, and the launcher recorded by the token's immutable `creator()`.

## Known limitations

- This code has not received an independent audit or public security contest.
- `block.timestamp` may vary within normal block-producer bounds; it cannot raise the fee and cannot move it outside
  100-300 bps.
- Claims revert if the immutable recipient refuses native ETH. No administrator can rescue or redirect those funds.
- The position lock prevents configured liquidity withdrawal; it does not guarantee demand, price appreciation,
  profitable trading, absence of MEV, or safety of external routers and interfaces.
- A production claim additionally requires reviewed deployment, runtime hashes, verified source, Mainnet bytecode
  parity, security status, and explicit interface activation.
