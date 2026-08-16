import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const skillRoot = process.env.PROGRAMMABLE_SKILL_ROOT;
if (!skillRoot) throw new Error("PROGRAMMABLE_SKILL_ROOT is required");

const canonicalCore = await import(pathToFileURL(path.join(skillRoot, "scripts/canonical-json-core.mjs")));
const openWorldCore = await import(pathToFileURL(path.join(skillRoot, "scripts/open-world-v2-core.mjs")));
const { canonicalJsonV2 } = canonicalCore;
const { architectureSnapshotSha256 } = openWorldCore;

const APP = "fade-v1";
const MARKET = "fade-native-v4-pool";
const HOOK = "0xa9acf28efa41a95f60a028652aead82376bca0cc";
const POOL_MANAGER = "0x000000000004444c5dc75cb358380d2e3de08a90";
const TREASURY = "0x4957f49620aff3adbbe8195a4f633e49cc93376c";
const SOURCE_REPOSITORY = "https://github.com/hazarxyz/fade-v1";

function shaBytes(value) {
  return `sha256:${crypto.createHash("sha256").update(value).digest("hex")}`;
}
function bytes(value) { return Buffer.from(`${canonicalJsonV2(value)}\n`); }
function record(value) { const valueBytes = bytes(value); return { value, bytes: valueBytes, sha256: shaBytes(valueBytes) }; }
function fileRecord(relativePath) { const valueBytes = fs.readFileSync(path.join(projectRoot, relativePath)); return { path: relativePath, bytes: valueBytes, sha256: shaBytes(valueBytes), byteLength: valueBytes.length }; }
function artifactBinding(artifactType, schemaId, relativePath, valueBytes) {
  return { artifactType, schemaId, path: relativePath, sha256: shaBytes(valueBytes), byteLength: valueBytes.length };
}
function builtin(schemaId) { return { kind: "builtin", schemaId, path: null, sha256: null, byteLength: null }; }
function endpoint(collection, id) { return { collection, id }; }

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

console.log(JSON.stringify({ ok: true, outputCount: outputFiles.size, submissionSha256: shaBytes(submissionBytes) }, null, 2));
