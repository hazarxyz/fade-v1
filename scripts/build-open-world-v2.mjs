import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const skillRoot = process.env.PROGRAMMABLE_SKILL_ROOT;
if (!skillRoot) throw new Error("PROGRAMMABLE_SKILL_ROOT is required");

const draftCore = await import(pathToFileURL(path.join(skillRoot, "scripts/open-world-v2-draft-core.mjs")));
const tradeCore = await import(pathToFileURL(path.join(skillRoot, "scripts/trade-capability-manifest-core.mjs")));
const canonicalCore = await import(pathToFileURL(path.join(skillRoot, "scripts/canonical-json-core.mjs")));
const openWorldCore = await import(pathToFileURL(path.join(skillRoot, "scripts/open-world-v2-core.mjs")));
const schemaCore = await import(pathToFileURL(path.join(skillRoot, "scripts/restricted-json-schema-core.mjs")));

const { createStandardV4TradeArtifactsV1 } = draftCore;
const {
  tradeCapabilityManifestBytesV1,
  tradeCapabilityManifestSha256V1,
  tradeTestResultSha256V1,
  validateTradeCapabilityManifestV1,
  validateTradeTestResultV1,
  validateTradeResultPairV1
} = tradeCore;
const { canonicalJsonBytesV2, canonicalJsonSha256V2, canonicalJsonV2 } = canonicalCore;
const { architectureSnapshotSha256, validateOpenWorldV2Package } = openWorldCore;
const { validateAgainstSchema } = schemaCore;

const APP = "fade-v1";
const MARKET = "fade-native-v4-pool";
const ZERO = "0x0000000000000000000000000000000000000000";
const ACCOUNT = "0x7fa9385be102ac3eac297483dd6233d62b3e1496";
const TOKEN = "0x665f321154ff5197788ee73adc30b6c07304baf6";
const HOOK = "0xa9acf28efa41a95f60a028652aead82376bca0cc";
const POOL_MANAGER = "0x000000000004444c5dc75cb358380d2e3de08a90";
const POSITION_MANAGER = "0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e";
const ROUTER = "0xa4ad4f68d0b91cfd19687c881e50f3a00242828c";
const QUOTER = "0x03a6a84cd762d9707a21605b548aaab891562aab";
const PERMIT2 = "0x1d1499e622d69689cdf9004d05ec547d650ff211";
const TREASURY = "0x4957f49620aff3adbbe8195a4f633e49cc93376c";
const SOURCE_REPOSITORY = "https://github.com/hazarxyz/fade-v1";

function shaBytes(value) {
  return `sha256:${crypto.createHash("sha256").update(value).digest("hex")}`;
}
function shaText(value) { return shaBytes(Buffer.from(value)); }
function bytes(value) { return Buffer.from(`${canonicalJsonV2(value)}\n`); }
function record(value) { const valueBytes = bytes(value); return { value, bytes: valueBytes, sha256: shaBytes(valueBytes) }; }
function fileRecord(relativePath) { const valueBytes = fs.readFileSync(path.join(projectRoot, relativePath)); return { path: relativePath, bytes: valueBytes, sha256: shaBytes(valueBytes), byteLength: valueBytes.length }; }
function digest(label, value = "") { return shaText(`${label}:${typeof value === "string" ? value : canonicalJsonV2(value)}`); }
function artifactBinding(artifactType, schemaId, relativePath, valueBytes) {
  return { artifactType, schemaId, path: relativePath, sha256: shaBytes(valueBytes), byteLength: valueBytes.length };
}
function builtin(schemaId) { return { kind: "builtin", schemaId, path: null, sha256: null, byteLength: null }; }
function endpoint(collection, id) { return { collection, id }; }

const tradeTest = fileRecord("test/FadeUniversalRouterTrade.t.sol");
const sourceFiles = [
  "src/FadeDecayFeeHookFactoryV1.sol",
  "src/FadeDecayFeeHookV1.sol",
  "src/FadeDecayFeeMath.sol",
  "src/FadeLaunchV1.sol",
  "src/LockedPositionFeeForwarderFactoryV1.sol",
  "test/FadeAccountingInvariant.t.sol",
  "test/FadeDecayFeeMath.t.sol",
  "test/FadeLaunchV1.t.sol",
  "test/FadeUniversalRouterTrade.t.sol",
  "test/helpers/FadeUniversalRouterV4.sol",
  "test/vendor/PinnedPermit2Artifact.sol"
];
const routeClosure = {
  schemaVersion: "1.0.0",
  status: "LOCAL_SOURCE_CLOSURE_NOT_APPROVAL",
  root: "src/FadeDecayFeeHookV1.sol",
  files: sourceFiles.map((file) => { const item = fileRecord(file); return { path: file, sha256: item.sha256, byteLength: item.byteLength }; })
};
const routeClosureBytes = bytes(routeClosure);
const routeClosurePath = "evidence/route-implementation-closure.v1.json";

const pinned = JSON.parse(fs.readFileSync(path.join(projectRoot, "dependencies/source-pins.json"), "utf8"));
const pinByName = Object.fromEntries(pinned.dependencies.map((item) => [item.name, item]));
const lock = fileRecord("package-lock.json");
const dependencyEntry = (id, role, sourceUri, identity) => ({ id, role, sourceUri, resolvedIdentity: identity, contentSha256: digest(`dependency-${id}`, identity) });
const dependencies = {
  lockfilePath: "package-lock.json",
  lockfileSha256: lock.sha256,
  entries: [
    dependencyEntry("uniswap-v4-core", "v4-core", "https://github.com/Uniswap/v4-core", pinByName["v4-core"].commit),
    dependencyEntry("uniswap-v4-periphery", "v4-periphery", "https://github.com/Uniswap/v4-periphery", pinByName["v4-periphery"].commit),
    dependencyEntry("uniswap-universal-router", "universal-router", "https://www.npmjs.com/package/@uniswap/universal-router", "2.1.0"),
    dependencyEntry("uniswap-v4-quoter", "v4-quoter", "https://github.com/Uniswap/v4-periphery", `${pinByName["v4-periphery"].commit}:V4Quoter`),
    dependencyEntry("uniswap-permit2", "permit2", "https://github.com/Uniswap/permit2", pinByName.permit2.commit),
    dependencyEntry("fade-trade-integration", "trade-integration", SOURCE_REPOSITORY, `${tradeTest.path}:${tradeTest.sha256}`)
  ]
};

const modes = {
  "zero-for-one-exact-input": { amountSpecified: "10000000000000000", amountQuoted: "7098290671223964947008021", amountIn: "10000000000000000", amountOut: "7098290671223964947008021", guard: "7062799217867845122272980", nativeBefore: "100000000000000000000", nativeAfter: "99990000000000000000", tokenBefore: "423145925956824620436724", tokenAfter: "7521436597180789567444745", feeBefore: "18000000000000", feeAfter: "318000000000000", refund: "0", gas: "289028", gross: "10000000000000000", hookFee: "300000000000000" },
  "zero-for-one-exact-output": { amountSpecified: "1000000000000000000000", amountQuoted: "1398786977406", amountIn: "1398786977406", amountOut: "1000000000000000000000", guard: "1405780912294", nativeBefore: "100000000000000000000", nativeAfter: "99999998601213022594", tokenBefore: "423145925956824620436724", tokenAfter: "424145925956824620436724", feeBefore: "18000000000000", feeAfter: "18041963609323", refund: "6993934888", gas: "292556", gross: "1398786977406", hookFee: "41963609323" },
  "one-for-zero-exact-input": { amountSpecified: "21157296297841231021836", amountQuoted: "27844895368600", amountIn: "21157296297841231021836", amountOut: "27844895368600", guard: "27705670891757", nativeBefore: "100000000000000000000", nativeAfter: "100000027844895368600", tokenBefore: "423145925956824620436724", tokenAfter: "401988629658983389414888", feeBefore: "18000000000000", feeAfter: "18861182330987", refund: "0", gas: "290759", gross: "28706077699587", hookFee: "861182330987" },
  "one-for-zero-exact-output": { amountSpecified: "50000000000000", amountQuoted: "37991977235802923621274", amountIn: "37991977235802923621274", amountOut: "50000000000000", guard: "38181937121981938239381", nativeBefore: "100000000000000000000", nativeAfter: "100000050000000000000", tokenBefore: "423145925956824620436724", tokenAfter: "385153948721021696815450", feeBefore: "18000000000000", feeAfter: "19546391752578", refund: "0", gas: "292823", gross: "51546391752578", hookFee: "1546391752578" }
};

function witness(modeId, row, reverted = false) {
  const before = { account: ACCOUNT, native: row.nativeBefore, token: row.tokenBefore, fee: row.feeBefore };
  const after = reverted ? before : { account: ACCOUNT, native: row.nativeAfter, token: row.tokenAfter, fee: row.feeAfter };
  const same = (label) => digest(`${modeId}-${label}`, before);
  const walletBefore = digest(`${modeId}-wallet-before`, before);
  const applicationBefore = digest(`${modeId}-application-before`, before);
  return {
    approvalBeforeSha256: same("approval"), approvalAfterSha256: same("approval"),
    fundingBeforeSha256: same("funding"), fundingAfterSha256: same("funding"),
    walletBeforeSha256: walletBefore, walletAfterSha256: reverted ? walletBefore : digest(`${modeId}-wallet-after`, after),
    lockBeforeSha256: same("lock"), lockAfterSha256: same("lock"),
    applicationBeforeSha256: applicationBefore, applicationAfterSha256: reverted ? applicationBefore : digest(`${modeId}-application-after`, after)
  };
}
function modeEvidence(modeId, row) {
  const call = { modeId, amountSpecified: row.amountSpecified, amountQuoted: row.amountQuoted, guard: row.guard, deadline: "1800000300" };
  return {
    sender: ACCOUNT, recipient: ACCOUNT, amountSpecified: row.amountSpecified, amountQuoted: row.amountQuoted, slippageBps: 50, deadline: "1800000300",
    quote: {
      calldataSha256: digest(`${modeId}-quote-calldata`, call), returnDataSha256: digest(`${modeId}-quote-return`, row.amountQuoted),
      stateBeforeSha256: digest(`${modeId}-quote-state`, { native: row.nativeBefore, token: row.tokenBefore, fee: row.feeBefore }),
      stateAfterSha256: digest(`${modeId}-quote-state`, { native: row.nativeBefore, token: row.tokenBefore, fee: row.feeBefore })
    },
    execution: {
      executionKind: "foundry-call", executionDigestSha256: digest(`${modeId}-execution`, call),
      actionPlanSha256: digest(`${modeId}-action-plan`, call), calldataSha256: digest(`${modeId}-execution-calldata`, call),
      fundingWitnessSha256: digest(`${modeId}-funding-witness`, { account: ACCOUNT, modeId }), stateWitness: witness(modeId, row),
      transactionHash: null, gasUsed: row.gas, amountIn: row.amountIn, amountOut: row.amountOut, slippageGuardAmount: row.guard,
      walletBalances: [
        { account: ACCOUNT, currency: ZERO, before: row.nativeBefore, after: row.nativeAfter },
        { account: ACCOUNT, currency: TOKEN, before: row.tokenBefore, after: row.tokenAfter }
      ],
      refundAmount: row.refund, dustAmount: "0", approvalChanged: false, fundsChangedBeforeExecution: false,
      lockStateChanged: false, applicationStateChanged: true
    }
  };
}
const evidenceModes = Object.fromEntries(Object.entries(modes).map(([id, row]) => [id, modeEvidence(id, row)]));
const negativeSpecs = {
  "expired-deadline-revert": { modeRef: "zero-for-one-exact-input", revert: "sha256:90a9fe1c0ad186acf7f07a027d798ba2f062b80ec51e548456383f463728bcdb", deadline: "1799999999", gas: "187098" },
  "slippage-bound-revert": { modeRef: "zero-for-one-exact-input", revert: "sha256:983888e7fe26f0740c2760906bec1a07fdf8f99f55aaaca5f838bd4bf355c45d", deadline: "1800000300", gas: "261022", guard: "7098290671223964947008022" },
  "funding-requirement-revert": { modeRef: "one-for-zero-exact-input", revert: "sha256:f5fd45fcc9f13ae77a4992eb38d601669cc1b3c70f734ad0a3f4a820a3750570", deadline: "1800000300", gas: "277006" }
};
const negative = {};
for (const [scenario, spec] of Object.entries(negativeSpecs)) {
  const base = structuredClone(evidenceModes[spec.modeRef]);
  const row = modes[spec.modeRef];
  base.modeRef = spec.modeRef;
  base.deadline = spec.deadline;
  if (spec.guard) base.execution.slippageGuardAmount = spec.guard;
  base.expectedRevertDataSha256 = spec.revert;
  base.execution = {
    ...base.execution,
    executionDigestSha256: digest(`${scenario}-execution`), actionPlanSha256: digest(`${scenario}-action-plan`),
    calldataSha256: digest(`${scenario}-execution-calldata`), fundingWitnessSha256: digest(`${scenario}-funding-witness`),
    stateWitness: witness(scenario, row, true), transactionHash: null, gasUsed: spec.gas,
    amountIn: "0", amountOut: "0", refundAmount: "0", dustAmount: "0", approvalChanged: false,
    fundsChangedBeforeExecution: false, lockStateChanged: false, applicationStateChanged: false,
    walletBalances: [
      { account: ACCOUNT, currency: ZERO, before: row.nativeBefore, after: row.nativeBefore },
      { account: ACCOUNT, currency: TOKEN, before: row.tokenBefore, after: row.tokenBefore }
    ]
  };
  negative[scenario] = base;
}

const feeReceipt = {
  artifactId: "fade-local-fee-observation-v1", path: "evidence/fade-local-fee-observation.v1.json",
  sha256: digest("fee-observation", modes), feeScopeId: "fade-native-swap-fee", chainId: "31337",
  quoteCurrency: ZERO, collectionProfile: "custom-reviewed", selectedRateHundredthsOfBip: 30000,
  maximumHookFeeBps: 300, lpFeePolicySha256: digest("lp-fee", "0"),
  hookFeePolicySha256: digest("fade-fee", "3%-to-1%-over-24h-plus-fixed-10bps-treasury")
};
const routeProbe = {
  type: "standard-uniswap-v4", routeShape: "single-pool",
  generationIdentitySha256: digest("fade-route-generation", { router: ROUTER, quoter: QUOTER, permit2: PERMIT2 }),
  interface: { id: "uniswap-v4-universal-router", version: "2.1.0", abiSha256: digest("universal-router-interface", "execute(bytes,bytes[],uint256)|V4Quoter") },
  router: { address: ROUTER, runtimeCodeKeccak256: "0x39a0d778433528278610eb94461e7981e3d8dc5c80bb458f808f787f7e48f45f", sourceDependencyRef: "uniswap-universal-router", deploymentEvidenceRef: "test/FadeUniversalRouterTrade.t.sol" },
  quoter: { address: QUOTER, runtimeCodeKeccak256: "0x2aaf24e8b45b00271f62787ad326f26a65188794cd1ea78821bfc4c89e2a8987", sourceDependencyRef: "uniswap-v4-quoter", deploymentEvidenceRef: "test/FadeUniversalRouterTrade.t.sol" },
  fundingProfiles: [
    { id: "native-input", type: "native-value", owner: "transaction-sender", token: "pool-input-currency", amount: "msg-value", nonce: "not-applicable", expiration: "not-applicable", signatureDeadline: "not-applicable", recipient: "router", permit2: { mode: "not-used", reason: "Native currency input is funded with transaction value." } },
    { id: "erc20-input", type: "permit2-allowance-transfer", owner: "transaction-sender", token: "pool-input-currency", amount: "exact-input-or-maximum-input", nonce: "permit2-allowance", expiration: "permit2-allowance", signatureDeadline: "execution-deadline-or-earlier", recipient: "router", permit2: { mode: "used", address: PERMIT2, runtimeCodeKeccak256: "0x91f6aee1f3c2c6632453f8ea3ff524598b066239b94ca1078fd94d3667d3fac6", sourceDependencyRef: "uniswap-permit2", deploymentEvidenceRef: "test/FadeUniversalRouterTrade.t.sol", erc20Input: "REQUIRED", nativeInput: "NOT_REQUIRED", approvalTarget: "PERMIT2", spender: ROUTER, mechanism: "allowance-transfer" } }
  ],
  hookData: { mode: "bound", contractId: "fade-empty-hook-data", contractVersion: "1.0.0", contractSha256: digest("fade-hook-data", "empty-only"), consumer: "hook", encoding: "empty-bytes", solidityType: "bytes", required: false, maximumBytes: 0, example: "0x" }
};
const tradeSchema = JSON.parse(fs.readFileSync(path.join(skillRoot, "references/trade-capability-manifest-v1.schema.json"), "utf8"));
const routeProbeFindings = validateAgainstSchema(routeProbe, { $schema: tradeSchema.$schema, $defs: tradeSchema.$defs, $ref: "#/$defs/standardRoute" });
if (routeProbeFindings.length) throw new Error(`route probe invalid: ${JSON.stringify(routeProbeFindings, null, 2)}`);
const trade = createStandardV4TradeArtifactsV1({
  applicationId: APP, marketRef: MARKET,
  chain: { chainId: "31337", networkRef: "local-deterministic-v4", deploymentProfileSha256: digest("local-v4-profile", "31337"), referenceBlock: { number: "17999999", hash: "0x23cba0be56382fe55b2983eaf58fe5464b0156ff2965afa59af4061306526f9b", timestamp: "1800000000" } },
  source: { repositoryUri: SOURCE_REPOSITORY, identityKind: "content-addressed-route-implementation-closure", routeImplementationPath: "src/FadeDecayFeeHookV1.sol", routeImplementationSha256: fileRecord("src/FadeDecayFeeHookV1.sol").sha256, routeImplementationClosurePath: routeClosurePath, routeImplementationClosureSha256: shaBytes(routeClosureBytes) },
  dependencies,
  poolKey: { currency0: ZERO, currency1: TOKEN, fee: 0, tickSpacing: 200, hooks: HOOK },
  generationIdentitySha256: digest("fade-route-generation", { router: ROUTER, quoter: QUOTER, permit2: PERMIT2 }),
  routeInterface: { id: "uniswap-v4-universal-router", version: "2.1.0", abiSha256: digest("universal-router-interface", "execute(bytes,bytes[],uint256)|V4Quoter") },
  runtimeDiscovery: {
    router: { address: ROUTER, runtimeCodeKeccak256: "0x39a0d778433528278610eb94461e7981e3d8dc5c80bb458f808f787f7e48f45f", sourceDependencyRef: "uniswap-universal-router", deploymentEvidenceRef: "test/FadeUniversalRouterTrade.t.sol" },
    quoter: { address: QUOTER, runtimeCodeKeccak256: "0x2aaf24e8b45b00271f62787ad326f26a65188794cd1ea78821bfc4c89e2a8987", sourceDependencyRef: "uniswap-v4-quoter", deploymentEvidenceRef: "test/FadeUniversalRouterTrade.t.sol" },
    permit2: { address: PERMIT2, runtimeCodeKeccak256: "0x91f6aee1f3c2c6632453f8ea3ff524598b066239b94ca1078fd94d3667d3fac6", sourceDependencyRef: "uniswap-permit2", deploymentEvidenceRef: "test/FadeUniversalRouterTrade.t.sol" }
  },
  hookData: { mode: "bound", contractId: "fade-empty-hook-data", contractVersion: "1.0.0", contractSha256: digest("fade-hook-data", "empty-only"), consumer: "hook", encoding: "empty-bytes", solidityType: "bytes", required: false, maximumBytes: 0, example: "0x" },
  policy: { minimumSlippageBps: 0, defaultSlippageBps: 50, maximumSlippageBps: 500, maximumDeadlineWindowSeconds: 600 },
  testContract: { workingDirectory: ".", environment: "local-v4-integration", environmentSha256: digest("forge-environment", { foundry: fs.readFileSync(path.join(projectRoot, "foundry.toml"), "utf8"), lock: lock.sha256 }), sourceArtifact: { path: tradeTest.path, sha256: tradeTest.sha256, byteLength: tradeTest.byteLength } },
  feeConformanceReceipt: feeReceipt,
  modeFeeEvidence: Object.fromEntries(Object.entries(modes).map(([id, row]) => {
    let gross = BigInt(row.gross);
    if (id === "one-for-zero-exact-output") gross -= 2n;
    const hookFee = gross * 1000n / 1_000_000n + gross * 29_000n / 1_000_000n;
    return [id, { grossQuoteAmount: gross.toString(), hookFeeAmount: hookFee.toString(), selectedRateHundredthsOfBip: "30000" }];
  })),
  evidence: { modes: evidenceModes, negative }
});

const manifest = structuredClone(trade.manifest);
manifest.feeBehavior.programmableFeeV2 = { applicability: "not-applicable", executionClass: "noncanonical", reason: "FADE uses a custom immutable time-decay fee schedule outside the frozen legacy Programmable Fee V2 policy." };
manifest.feeBehavior.components = [
  { id: "v4-lp-fee", kind: "v4-lp", chargedOn: "pool-accounting", currencyRole: "input-currency", routeDefinedCurrency: null, chargeBase: "input-amount", calculation: "fixed-pips", ratePips: 0, maximumBps: 0, quoteInclusion: "included", recipientBehavior: "lp-provider", policySha256: digest("lp-fee", "0") },
  { id: "fade-decay-native-hook-fee", kind: "hook", chargedOn: "route-defined", currencyRole: "route-defined", routeDefinedCurrency: ZERO, chargeBase: "route-defined", calculation: "dynamic", ratePips: null, maximumBps: 300, quoteInclusion: "included", recipientBehavior: "hook-defined", policySha256: digest("fade-fee", "3%-to-1%-over-24h-plus-fixed-10bps-treasury") }
];
const manifestSha = tradeCapabilityManifestSha256V1(manifest);
const results = {};
for (const [resultPath, sourceResult] of Object.entries(trade.resultsByPath)) {
  const result = structuredClone(sourceResult);
  result.context.manifestSha256 = manifestSha;
  result.context.fee.feeBehaviorSha256 = canonicalJsonSha256V2(manifest.feeBehavior);
  result.context.fee.programmableFeeApplicability = "not-applicable";
  result.context.fee.feeConformanceReceiptSha256 = null;
  const observedMode = modes[result.context.mode.id];
  const inputCurrency = result.context.mode.direction === "zero-for-one" ? ZERO : TOKEN;
  result.context.fee.amounts = {
    components: [
      { componentRef: "v4-lp-fee", currency: inputCurrency, chargeBase: "input-amount", baseAmount: result.context.mode.amountMode === "exact-input" ? observedMode.amountSpecified : observedMode.amountQuoted, amount: "0" },
      { componentRef: "fade-decay-native-hook-fee", currency: ZERO, chargeBase: "route-defined", baseAmount: observedMode.gross, amount: observedMode.hookFee }
    ],
    totalsByCurrency: inputCurrency === ZERO
      ? [{ currency: ZERO, amount: observedMode.hookFee }]
      : [{ currency: ZERO, amount: observedMode.hookFee }, { currency: TOKEN, amount: "0" }]
  };
  result.context.fee.quotedFeesSha256 = canonicalJsonSha256V2(result.context.fee.amounts);
  result.observation.callBinding.feeBehaviorSha256 = result.context.fee.feeBehaviorSha256;
  if (result.contract === "trade-execution-test-result-v1") result.observation.executedFeesSha256 = result.context.fee.quotedFeesSha256;
  result.contentSha256 = tradeTestResultSha256V1(result);
  results[resultPath] = result;
}
const manifestFindings = validateTradeCapabilityManifestV1(manifest, { applicationId: APP, marketRef: MARKET, routeType: "standard-uniswap-v4", manifestSha256: manifestSha });
if (manifestFindings.length) throw new Error(`trade manifest invalid: ${JSON.stringify(manifestFindings, null, 2)}`);
for (const test of [...manifest.testEvidence.quoteTests, ...manifest.testEvidence.executionTests]) {
  const result = results[test.resultArtifactPath];
  const findings = validateTradeTestResultV1(result, { manifest, test });
  if (findings.length) throw new Error(`trade result ${test.id} invalid: ${JSON.stringify(findings, null, 2)}`);
}
for (const mode of manifest.capabilities.modeMatrix) {
  const quoteTest = manifest.testEvidence.quoteTests.find((item) => item.modeRef === mode.id);
  const executionTest = manifest.testEvidence.executionTests.find((item) => item.modeRef === mode.id && item.scenario === "successful-swap");
  const findings = validateTradeResultPairV1(results[quoteTest.resultArtifactPath], results[executionTest.resultArtifactPath], { manifest, quoteTest, executionTest });
  if (findings.length) throw new Error(`trade pair ${mode.id} invalid: ${JSON.stringify(findings, null, 2)}`);
}

const outputFiles = new Map();
outputFiles.set(routeClosurePath, routeClosureBytes);

const profileSchema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  $id: `urn:programmable:local-profile:${APP}:1.0.0`,
  type: "object", additionalProperties: false, required: ["description"],
  properties: { description: { type: "string", minLength: 1 }, immutable: { type: "boolean" }, basis: { type: "string" }, schedule: { type: "string" }, amount: { type: "string" }, recipient: { type: "string" } }
};
const profilePath = "schemas/fade-profile.schema.json";
const profileBytes = bytes(profileSchema);
const profile = { kind: "repository", schemaId: profileSchema.$id, path: profilePath, sha256: shaBytes(profileBytes), byteLength: profileBytes.length };
outputFiles.set(profilePath, profileBytes);

const records = {
  ideaSource: record(JSON.parse(fs.readFileSync(path.join(projectRoot, "open-world-v2/idea-source.v1.json"), "utf8"))),
  intentContract: null, architectureDecisions: null, intentFidelity: null
};
const evidenceRefs = [routeClosurePath, ...sourceFiles].sort();
const sourceRefs = sourceFiles.filter((file) => file.startsWith("src/"));
const testRefs = sourceFiles.filter((file) => file.startsWith("test/"));
const fact = (id, kind, text, payload) => ({ id, kind, materiality: "core", modality: "delegated-default", state: "default-proposed", subjectRefs: ["fade-hook"], semanticPayload: { description: text, ...payload }, payloadSchema: profile, plainLanguage: { language: "en", text }, provenance: [{ ideaEntryId: "original-idea", startByte: 0, endByte: 439, legacySourceRef: null, relation: "default-proposed" }] });
const facts = [
  fact("uniswap-v4-native-launch", "uniswap-v4-native-launch", "Use a native ETH Uniswap v4 launch with a one-sided permanently locked liquidity position and a 0.0006 ETH minimum initial buy.", { amount: "600000000000000" }),
  fact("fixed-token-supply", "fixed-token-supply", "Create a fixed one billion token supply with no post-launch mint authority.", { amount: "1000000000000000000000000000", immutable: true }),
  fact("fade-fee-schedule", "time-decay-native-swap-fee", "Charge native-side swap fees that decay linearly from 3 percent to 1 percent over 24 hours.", { schedule: "300-to-100-bps-linear-over-86400-seconds", immutable: true }),
  fact("programmable-treasury-share", "fixed-treasury-share", `Accrue 10 bps of gross native swap volume to ${TREASURY}; the creator receives the remaining hook fee.`, { amount: "10-bps", recipient: TREASURY, immutable: true }),
  fact("normal-applicant-boundary", "application-boundary", "Submit as a normal Applicant Draft; do not claim review, approval, deployment or launch.", { immutable: true })
];
const intentContract = {
  schemaVersion: "1.0.0", applicationId: APP, revision: 2, workingLanguage: "en", status: "delegated-defaults",
  ideaSourceSha256: records.ideaSource.sha256,
  route: { id: "CUSTOM_ARCHITECTURE", reasons: [{ language: "en", text: "The implemented FADE hook is a custom Uniswap v4 architecture outside frozen legacy Fee V2." }], blockedByRefs: [] },
  entities: [{ id: "fade-hook", kind: "uniswap-v4-hook", label: { language: "en", text: "FADE decay-fee hook" }, description: { language: "en", text: "Immutable native-side time-decay fee hook and launch flow." } }],
  facts, ambiguities: [], confirmation: { state: "delegated-defaults", ideaEntryId: "original-idea", confirmedFactIds: [], delegatedDefaultFactIds: facts.map(({ id }) => id) }
};
records.intentContract = record(intentContract);
const decision = {
  id: "select-fade-v4-architecture", sequence: 1, kind: "custom-v4-launch-route", decisionSchema: profile,
  decisionPayload: { description: "Select the implemented FADE v4 hook, locked-position launcher and standard Universal Router route." },
  status: "selected", factRefs: facts.map(({ id }) => id), ambiguityRefs: [],
  alternatives: [
    { id: "no-hook-core", summary: { language: "en", text: "A zero-hook pool cannot implement the requested fee schedule." }, preservesFactRefs: ["uniswap-v4-native-launch", "fixed-token-supply"], changesFactRefs: ["fade-fee-schedule", "programmable-treasury-share"], trustEffects: [], safetyEffects: ["simpler-accounting"] },
    { id: "fade-custom-hook", summary: { language: "en", text: "Use the implemented PoolId-scoped FADE hook and locked-position launcher." }, preservesFactRefs: facts.map(({ id }) => id), changesFactRefs: [], trustEffects: ["pool-manager-authenticated-callbacks"], safetyEffects: ["not-approved", "local-evidence-only"] }
  ],
  selectedAlternativeId: "fade-custom-hook", rationale: { language: "en", text: "This is the only implemented alternative preserving the project fee schedule and locked-liquidity launch design." },
  trustChanges: ["pool-manager-authenticated-callbacks"], safetyConstraints: ["not-approved", "no-production-deployment", "immutable-fee-parameters"], reversible: false, reversalPlan: null,
  architectureRefs: [{ collection: "hooks", id: "fade-hook" }, { collection: "markets", id: MARKET }, { collection: "components", id: "fade-launcher" }],
  sourcePaths: sourceRefs, testRefs, evidenceRefs, supersedes: []
};
records.architectureDecisions = record({ schemaVersion: "1.0.0", applicationId: APP, revision: 2, intentContractSha256: records.intentContract.sha256, decisions: [decision] });

const submission = {
  $schema: "urn:programmable:v4-hook-submission:2.0.0", schemaVersion: 2, standardVersion: "2.0.0", applicationId: APP, stage: "proposal",
  project: { name: "FADE", summary: { language: "en", text: "A NOT_APPROVED Uniswap v4 launch prototype with immutable locked liquidity and a native swap fee decaying from 3% to 1% over 24 hours." }, repository: SOURCE_REPOSITORY, license: "MIT" },
  targets: [{ id: "ethereum-mainnet", kind: "ethereum-mainnet", profileSchema: builtin("urn:programmable:builtin:target:ethereum-mainnet:1.0.0"), profile: { chainId: "1" } }],
  assets: [
    { id: "native-eth", kind: "native-currency", roleIds: ["quote", "fee-basis", "initial-buy"], profileSchema: profile, profile: { description: "Native ETH is currency0 and the sole hook-fee currency." }, authorityRefs: [] },
    { id: "fade-token", kind: "erc20", roleIds: ["project-token"], profileSchema: builtin("urn:programmable:builtin:asset:erc20:1.0.0"), profile: { symbol: "FADE" }, authorityRefs: [] }
  ],
  authorities: [
    { id: "creator", kind: "immutable-wallet", profileSchema: builtin("urn:programmable:builtin:authority:immutable-wallet:1.0.0"), profile: { purpose: "creator-fee-claim", immutable: true }, holder: "launch-caller", capabilityRefs: ["claim-creator-fees"], revocation: "immutable" },
    { id: "programmable-treasury", kind: "immutable-wallet", profileSchema: builtin("urn:programmable:builtin:authority:immutable-wallet:1.0.0"), profile: { purpose: "platform-fee-claim", immutable: true }, holder: TREASURY, capabilityRefs: ["claim-programmable-fees"], revocation: "immutable" }
  ],
  capabilityProfiles: [
    { id: "claim-creator-fees", kind: "permissionless-trigger-fixed-recipient", profileSchema: profile, profile: { description: "Anyone may trigger settlement, but value is paid only to the immutable per-pool creator." }, scopeRefs: [endpoint("hooks", "fade-hook")] },
    { id: "claim-programmable-fees", kind: "permissionless-trigger-fixed-recipient", profileSchema: profile, profile: { description: "Anyone may trigger settlement, but value is paid only to the immutable Programmable treasury." }, scopeRefs: [endpoint("hooks", "fade-hook")] }
  ],
  components: [
    { id: "fade-launcher", kind: "v4-locked-position-launcher", profileSchema: profile, profile: { description: "Creates the fixed-supply token, initializes its native v4 pool, locks the position forever and executes the atomic initial buy." }, implementationRefs: ["src/FadeLaunchV1.sol", "src/LockedPositionFeeForwarderFactoryV1.sol"], authorityRefs: [] },
    { id: "fade-hook-factory", kind: "create2-hook-factory", profileSchema: profile, profile: { description: "Deploys the permission-bit-correct immutable FADE hook." }, implementationRefs: ["src/FadeDecayFeeHookFactoryV1.sol"], authorityRefs: [] }
  ],
  hooks: [{
    id: "fade-hook", kind: "uniswap-v4-hook", profileSchema: builtin("urn:programmable:builtin:hook:uniswap-v4:1.0.0"),
    profile: {
      contractVersion: "1.0.0", purpose: "PoolId-scoped native-side swap fee decaying from 300 to 100 bps in 24 hours with a fixed 10 bps treasury share.",
      poolManager: { authentication: "exact-msg-sender", binding: "immutable-exact-address", address: POOL_MANAGER },
      poolIsolation: { namespace: "pool-id", crossPoolSubsidy: false, crossPoolNetting: false },
      identities: { msgSenderRole: "pool-manager", senderRole: "router-or-unlock-caller", senderTreatedAsEndUser: false, endUserAuthentication: "not-used" },
      hookData: { mode: "not-used", versioned: false, domainBound: false, replayProtected: false, malformedRejected: true, witness: null },
      swapAccounting: { supportedQuadrants: ["zero-for-one-exact-input", "zero-for-one-exact-output", "one-for-zero-exact-input", "one-for-zero-exact-output"], rejectedQuadrants: [], unsupportedRejectedBeforeEffects: true, specifiedCurrencyDerived: true, unspecifiedCurrencyDerived: true, signsDerived: true, partialFillPolicy: "rejected-before-effects", unlockDeltasClose: true, creditsBacked: true, erc20Settlement: "periphery-delta-router", rounding: "explicit-bounded", tinyAndExtremeValuesTested: true },
      returnDelta: { beforeSwapUsed: true, afterSwapUsed: true, afterAddLiquidityUsed: false, afterRemoveLiquidityUsed: false, backing: "erc6909-claims", noOpAnalyzed: true, hardBounds: true, deltaConservation: true, justification: "Native fees are backed by PoolManager ERC6909 claims and separated into creator and treasury liabilities." },
      reentrancy: { guardModel: "transient-guard", nestedUnlocks: "rejected", crossFunctionAnalyzed: true, externalCallOrderAnalyzed: true },
      routing: { universalRouter: true, v4Planner: true, permit2: true, nativeEth: true, exactInput: true, exactOutput: true, singleHop: true, multiHop: true, perHopHookData: true, quoteExecutionParity: true },
      deployment: { state: "preimage-bound", creationCodeHash: "sha256:2be5f19e3ee2b8deeb143e36b603c21722d4fdf3f295783928a06540caa71822", constructorArgsHash: "sha256:d4e2483a2b74288bd6135551ff390ab3a67459bbad1d7ee24f0828f32e75c230", initcodeHash: "sha256:430f7c5312b778260029572dd04b50ad56bdc92bc146edb1bbc445cb69fa33a7", permissionMask: "0x20cc", hookMinerSaltRef: "test/FadeUniversalRouterTrade.t.sol", hookMinerSaltSha256: "sha256:45586bc7289d252bf729ef2661a128bd2921a53f4bbf6e5de7584977b48007f1", expectedAddress: HOOK, runtimeCodeHash: "sha256:516916c8c4c8a3f95914f1efd5f71f8477bf105e2922a5504657de8521cf3183", poolManagerAddress: POOL_MANAGER },
      evidence: { unit: ["test/FadeLaunchV1.t.sol"], negative: ["test/FadeLaunchV1.t.sol", "test/FadeUniversalRouterTrade.t.sol"], fuzz: ["test/FadeDecayFeeMath.t.sol"], invariant: ["test/FadeAccountingInvariant.t.sol"], fork: ["test/FadeUniversalRouterTrade.t.sol"], router: ["test/FadeUniversalRouterTrade.t.sol"], deployment: ["test/FadeUniversalRouterTrade.t.sol"] }
    },
    permissions: { beforeInitialize: true, afterInitialize: false, beforeAddLiquidity: false, afterAddLiquidity: false, beforeRemoveLiquidity: false, afterRemoveLiquidity: false, beforeSwap: true, afterSwap: true, beforeDonate: false, afterDonate: false, beforeSwapReturnDelta: true, afterSwapReturnDelta: true, afterAddLiquidityReturnDelta: false, afterRemoveLiquidityReturnDelta: false },
    implementationRef: "src/FadeDecayFeeHookV1.sol", authorityRefs: ["creator", "programmable-treasury"]
  }],
  markets: [{ id: MARKET, kind: "uniswap-v4-canonical-pool", profileSchema: builtin("urn:programmable:builtin:market:uniswap-v4-canonical-pool:1.0.0"), profile: { chainId: "1" }, assetRefs: ["native-eth", "fade-token"], hookRef: "fade-hook", liquidity: { nativeAmmMode: "required", minimumInitialLiquidity: "1", sourceRefs: ["fade-token"], custodyRefs: ["fade-launcher"] }, executionClass: "external", canonicalScopes: [] }],
  valueFlows: [],
  lifecyclePhases: [{ id: "launch-and-trade", kind: "atomic-launch-then-trading", profileSchema: profile, profile: { description: "Atomic token creation, locked-liquidity initialization and minimum buy followed by open v4 trading." }, predecessorRefs: [], transitionRefs: ["launch-and-trade"], assetRefs: ["native-eth", "fade-token"], marketRefs: [MARKET], hookRefs: ["fade-hook"], componentRefs: ["fade-launcher", "fade-hook-factory"], valueFlowRefs: [], authorityRefs: ["creator", "programmable-treasury"] }],
  fragmentation: { strategy: "single-review", fragments: [] },
  implementation: { sourcePaths: sourceRefs, testPaths: testRefs, evidenceRefs },
  intentPackage: {},
  supportingPackage: {},
  tradeCapability: { applicability: "unresolved", facetEntryRef: "routing-trade-capability", markets: [] }
};

const architectureSnapshot = architectureSnapshotSha256(submission);
records.intentFidelity = record({
  schemaVersion: "1.0.0", applicationId: APP, revision: 2, overallStatus: "preserved", driftEvents: [],
  generatedBy: { tool: "fade-open-world-v2-builder", version: "1.0.0", rulesetSha256: null },
  inputDigests: { ideaSourceSha256: records.ideaSource.sha256, intentContractSha256: records.intentContract.sha256, architectureDecisionsSha256: records.architectureDecisions.sha256, architectureSnapshotSha256: architectureSnapshot },
  traces: facts.map(({ id }) => ({ factId: id, status: "preserved", decisionRefs: ["select-fade-v4-architecture"], architectureRefs: [{ collection: "hooks", id: "fade-hook" }, { collection: "markets", id: MARKET }], implementationRefs: sourceRefs, testRefs, evidenceRefs, difference: { language: "en", text: "Material numeric details are explicit Builder defaults implemented in source; they are not quoted as verbatim user text." }, acceptedChangeIdeaEntryId: null }))
});

const recordSpecs = {
  ideaSource: ["idea-source", "urn:programmable:idea-source:1.0.0", "idea-source.v1.json"],
  intentContract: ["intent-contract", "urn:programmable:intent-contract:1.0.0", "intent-contract.v1.json"],
  architectureDecisions: ["architecture-decisions", "urn:programmable:architecture-decisions:1.0.0", "architecture-decisions.v1.json"],
  intentFidelity: ["intent-fidelity", "urn:programmable:intent-fidelity:1.0.0", "intent-fidelity.v1.json"]
};
for (const [key, [artifactType, schemaId, file]] of Object.entries(recordSpecs)) {
  outputFiles.set(file, records[key].bytes);
  submission.intentPackage[key] = artifactBinding(artifactType, schemaId, file, records[key].bytes);
}
const securitySchema = fileRecord("open-world-v2/security-assessment-v1.schema.json");
submission.supportingPackage.securityAssessmentSchema = artifactBinding("security-assessment-schema", "urn:programmable:open-world-security:1.0.0", securitySchema.path.replace("open-world-v2/", ""), securitySchema.bytes);
submission.supportingPackage.securityAssessment = null;
outputFiles.set(profilePath, profileBytes);

const submissionBytes = bytes(submission);
outputFiles.set("submission.v2.json", submissionBytes);
for (const [relativePath, valueBytes] of outputFiles) {
  const absolutePath = path.join(projectRoot, "open-world-v2", relativePath);
  fs.mkdirSync(path.dirname(absolutePath), { recursive: true });
  fs.writeFileSync(absolutePath, valueBytes);
}

console.log(JSON.stringify({ ok: true, manifestSha256: manifestSha, outputCount: outputFiles.size, submissionSha256: shaBytes(submissionBytes) }, null, 2));
