# Attribution

The locked one-sided launch and ETH fee-accounting design is adapted from the MIT-licensed
`0xprogrammable/programmable` Classic contracts at commit
`1788cf3e32116059a714d7574421cb8459a80f2b`.

FADE changes the fixed Classic fee into an immutable schedule that starts at 3.00%, decreases linearly over 24 hours,
and remains at 1.00%. The Programmable share stays fixed at 0.10 percentage points of gross canonical pool volume.
