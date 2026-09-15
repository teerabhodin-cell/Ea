# Phase C5 — Controlled Execution Path Contract

> **RETROSPECTIVE DOCUMENT** — reconstructed after implementation from
> surviving repository evidence (commit messages, code comments, test
> evidence) and accepted checkpoint records (RA-34, RA-36). This is
> **not** a claim that a formal contract document existed at the time
> C5 was implemented — none did. It is a description of what was
> actually built and verified, assembled retroactively so C5 has a
> single authoritative reference going forward.

Status: **DRAFT — pending QA review (RA-36.1)**

Scope: read-only reconstruction. Introduces no new code, no new
behavior, no new acceptance criteria beyond what the cited evidence
already establishes.

---

## 1. Source evidence

This document is built entirely from two commits and their surrounding
code, all still present in `MLQuantAI.mq5`:

```text
c5.0  (d0171917) 2026-09-08  feat(c5.0): wire candidate-to-safety-gate
                              pipeline into OnTick (Strategy Tester only)
c5.1  (9a940890) 2026-09-08  feat(c5.1): raise InpC5MaxVolume default to
                              observe SafetyGate ACCEPTED
```

No numbered "section" citations exist anywhere in the C5.0/C5.1 code or
commit messages (unlike C6.2/C6.3 — see
`Docs/PhaseC_C6_ExecutionDiscoveryContract.md`). Both commits are
self-contained: their own messages state the rationale directly. There
is no evidence of a separate structured chat-contract for C5 the way
C6.2/C6.3 evidently had one.

---

## 2. What C5 is

C5 ("controlled execution path") is the first end-to-end wiring of the
already-built, already-independently-tested pipeline —

```text
TradeCandidate -> RiskPlan -> AIDecision -> EligibilityDecision
    -> ExecutionRequest -> SafetyGate
```

— (Phase B5–B9 / C1–C2, all previously sealed) into `OnTick()`, so the
full chain can be observed running against real market data for the
first time, without ever reaching the broker.

Implementation lives in `MLQuantAI.mq5`'s `OnTick()`, inline (no
separate Include file — see §5 for the exact call sequence).

---

## 3. Gating — Strategy Tester only

```mql5
if(!MQLInfoInteger(MQL_TESTER)) return;
```

This check runs early in `OnTick()`, before `CRT_DetectV1()` or any
candidate-building step. C5's pipeline **does not run at all** outside
the Strategy Tester — a live or demo-chart attach never reaches any of
the code described in this document. (This gate was later loosened by
C6.6's ceremony-command protocol, which runs its own, separately
authorized dry-run/submit paths outside the Tester — that is out of
scope for this document; see RA-34.)

---

## 4. Authority boundary — the C5.0 "design freeze"

Quoting the code directly (`MLQuantAI.mq5`, C5.0 pipeline comment):

> "per the C5.0 design freeze (which bounded broker reachability, not
> durability)"

This is the precise, evidenced boundary: C5.0 bounds **broker
reachability** — it must never call `BrokerSubmission_Submit()` or
`OrderSend()` — but does **not** bound EventStore durability. This is
why C6.2/C6.3 Wave 1 (a later checkpoint) was able to add durable
`EXECUTION_REQUEST_CREATED`/`EXECUTION_DRY_RUN_COMPLETED` emission on
top of the same C5.0 fixture without violating C5.0's own freeze — see
`Docs/PhaseC_C6_ExecutionDiscoveryContract.md`.

Confirmed boundary, verified by the c5.0 commit's own diff and
message:

```text
NEVER calls: BrokerSubmission_Submit()
NEVER calls: OrderSend()
NEVER calls: EventStore_Log* directly for C5.0's own candidate/plan/
             decision content (this was added later by C6.2/C6.3 Wave 1,
             not by C5.0 itself)
Stops at:    SafetyGate_Evaluate()
Diagnostic:  LogInfo()/LogWarn() only
```

---

## 5. Pipeline sequence (as implemented)

In `OnTick()`, after the trigger-bar/`MarketContext` gate and the
`MQL_TESTER` gate above:

```text
1. CRT_DetectV1(ctx, crtResult)          — no detection, no log, return
2. CRT_ToTradeCandidate(ctx, crtResult, c5Candidate)
3. [C6.2/C6.3 Wave 1 discover-before-emit gate — see C6 doc]
4. Candidate_ToFeatureSnapshot(...)
5. Candidate_ToRiskPlan(...)             — via c5RiskCtx (target_risk_percent,
                                            sizing_method="FIXED_PERCENT_RISK",
                                            sizing_rules_version)
6. Synthetic InferenceResult             — no ONNX model exists yet; real
                                            InferenceResult contract shape,
                                            output_values[0] = InpC5StubPSuccess,
                                            referentially matched to the real
                                            FeatureSnapshot it was built from
7. Eligibility decision
8. ExecutionRequest construction
9. SafetyGate_Evaluate(...)              — terminal step; decision is
                                            SAFETY_GATE_ACCEPTED or REJECTED,
                                            logged, pipeline stops here
```

Step 6's synthetic inference is explicitly a stand-in: no trained model
exists at this checkpoint. The `InferenceResult` struct shape is real
and contract-valid; only its content is deterministic/synthetic
(`InpC5StubPSuccess`, default `1.0`).

---

## 6. Configuration inputs (verbatim from `MLQuantAI.mq5`)

```text
InpC5TargetRiskPercent        = 1.0    // RiskContext.target_risk_percent (1.0 == 1%)
InpC5SizingRulesVersion       = "C5_0_FIXTURE_SIZING_V1"
InpC5StubPSuccess             = 1.0    // synthetic InferenceResult.output_values[0], [0,1]
InpC5AIDecisionPolicyVersion  = "C5_0_FIXTURE_AI_POLICY_V1"
InpC5AIThresholdVersion       = "C5_0_FIXTURE_AI_THRESHOLD_V1"
InpC5AIAllowThreshold         = 0.5    // [0,1]
InpC5EligibilityPolicyVersion = "C5_0_FIXTURE_ELIGIBILITY_POLICY_V1"
InpC5MaxDailyLossPercent      = 0.0    // 0 = gate disabled
InpC5MaxDrawdownPercent       = 0.0    // 0 = gate disabled
InpC5MaxTotalExposurePercent  = 0.0    // 0 = gate disabled
InpC5MaxOpenPositions         = 0      // 0 = gate disabled
InpC5MinMarginLevel           = 0.0    // 0 = gate disabled
InpC5ExecutionPolicyVersion   = "C5_0_FIXTURE_EXECUTION_POLICY_V1"
InpC5MaxVolume                = 10.0   // ExecutionPolicy.max_volume — see §7 (C5.1)
InpC5MaxPlannedRiskAmount     = 1000.0 // ExecutionPolicy.max_planned_risk_amount
InpC5MaxDeviationPoints       = 0.0    // ExecutionPolicy.max_deviation_points, >= 0
```

---

## 7. C5.1 — the volume-cap correction

C5.0's original `InpC5MaxVolume` default was `0.01`. Per the c5.1 commit
message, this was **tighter than any risk-sized lot the fixed-fractional
sizing formula could produce** for XAUUSD at `target_risk_percent=1%`
— meaning C5.0, as shipped, could only ever produce `REJECTED`
(`EXECUTION_VOLUME_CAP_EXCEEDED`) verdicts, never `ACCEPTED`, making it
impossible to observe the gate's positive path at all.

c5.1 raised the default to `10.0` — not an invented number; it matches
the value already validated in
`Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5`. `InpC5MaxPlannedRiskAmount`
(`1000.0`) was already sufficient (real risk in observed runs was
~$10–100) and was left unchanged.

---

## 8. Verification evidence (as recorded in the commits)

**c5.0**: real MetaEditor compile (0 errors/0 warnings, all 10 new
dependency files present), C4.2/C4.3/C4.3.1 regression suites (ALL
PASS), and a full Strategy Tester run (`2026.01.01`–`2026.09.07`)
producing hundreds of real `ACCEPTED`/`REJECTED` gate verdicts and
structural-failure diagnostics, with final balance unchanged confirming
zero real `OrderSend` calls.

**c5.1**: real MetaEditor compile (0 errors/0 warnings) and a full
Strategy Tester run producing hundreds of real `ACCEPTED` verdicts
alongside at least one still-genuine `REJECTED` verdict and
structural-failure diagnostics (proving `SafetyGate` is still
evaluating, not bypassed), with final balance unchanged confirming zero
`OrderSend` calls.

---

## 9. Explicit non-goals / what C5 does not cover

- No broker submission, no `OrderSend`, under any input configuration.
- No live/demo-chart execution path (Strategy-Tester-only per §3).
- No durable EventStore emission of its own content (see §4 — that
  arrived later, via C6.2/C6.3 Wave 1, as a distinct, separately
  authorized checkpoint).
- No trained AI model (synthetic inference only, §5 step 6).
- No coverage of C6.1/C6.2/C6.3/C6.6 — see
  `Docs/PhaseC_C6_ExecutionDiscoveryContract.md` and
  `Docs/RA34_BaselineFreeze_ArchitectureAudit.md`.

---

## 10. Status

```text
C5.0 = DONE (RA-34 §2.1)
C5.1 = DONE (RA-34 §2.1)
```

This document does not reopen, alter, or reinterpret that classification
— it records the evidence behind it. See `Docs/RA34_BaselineFreeze_ArchitectureAudit.md`
for the full C5→C6.6 lineage this fits into.

**QA STATUS: DRAFT — awaiting review (RA-36.1).** Not yet staged, not
committed, not pushed.
