import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const manifest = JSON.parse(readFileSync(new URL("../spec/model-manifest.v1.json", import.meta.url), "utf8"));

assert.equal(manifest.schemaVersion, "fade.model-manifest.v1");
assert.equal(manifest.modelId, "fade-v1");
assert.equal(manifest.network.chainId, 1);
assert.equal(manifest.market.quoteAsset, "native-eth");
assert.equal(manifest.market.lpFeePips, 0);
assert.equal(manifest.liquidity.creatorEthDeposit, "0");
assert.equal(manifest.liquidity.oneSided, true);
assert.equal(manifest.liquidity.permanentlyLocked, true);
assert.equal(manifest.fees.basis, "gross-canonical-pool-volume");
assert.equal(manifest.fees.startTotalBps, 300);
assert.equal(manifest.fees.endTotalBps, 100);
assert.equal(manifest.fees.decayDurationSeconds, 86_400);
assert.equal(manifest.fees.programmableBps, 10);
assert.equal(manifest.fees.programmableTreasury, "0x4957f49620AFf3Adbbe8195a4f633E49cc93376c");
assert.equal(manifest.authority.owner, false);
assert.equal(manifest.deployment.performed, false);
assert.equal(manifest.review.programmableApproved, false);
assert.equal(manifest.review.launchAuthorized, false);

process.stdout.write("FADE_MODEL_MANIFEST_VALID\n");
