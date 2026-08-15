# Phase B7 — RiskPlan / Position Sizing: Kickoff Draft (Not Implemented)

**Status: Planning notes only. No code exists for anything in this
document.** Captured here so a genuinely useful design proposal isn't
lost, after it was correctly deferred out of B6.3 for being out of B6's
scope — B6's own kickoff message explicitly prohibited "RiskPlan/
position sizing" work, and that boundary was reaffirmed when this
proposal came in. This document is B7 INPUT, not a B7 spec — it needs
its own kickoff/DoD gate from the user before any of it is built,
exactly like every other phase in this project.

## Proposal (as given, evaluated favorably on technical merit)

The core idea: separate a `RiskPlan`'s **identity** from its
**content**, the same pattern `context_hash`/`candidate_hash` already
proved out in B6.1/B6.2/B6.3 — an id that stays stable across
re-derivations of the same intent, and a content hash that moves
whenever the decision-bearing payload actually changes.

```cpp
risk_plan_id = Ids_RiskPlanId(candidate_id, sizing_rules_version);
plan_hash    = SHA256(canonical_payload);
```

`risk_plan_id` must NOT depend on `balance`/`equity`/`risk_amount`/
`lot_size` — those are computed OUTPUTS of sizing, not identity seeds.
Same candidate + same `sizing_rules_version` → same `risk_plan_id`,
always, even if the computed sizing itself differs run to run because
account state moved.

### Canonical numeric serialization (independently valuable — not risk-plan-specific)

The one piece of this proposal that is NOT scoped to B7/RiskPlan at
all: hash paths anywhere in this project must never use
`DoubleToString(x, Digits())`/`_Digits()`/`Digits()` (the live-chart
built-ins) — those read runtime/broker state, which would make a hash
drift with the symbol/chart context instead of staying a pure function
of its inputs. This is already correctly avoided by
`context_hash`/`detector_hash`/`candidate_hash` today (each takes an
explicit `digits` parameter sourced from `symbol_spec.digits`, never
reads a live built-in) — worth stating explicitly in
`Docs/PhaseB_B6_3_HashContractSpec.md` as a standing rule for any
future hash, rather than only being implicitly true by not having been
violated yet. A set of canonical formatting helpers
(`CanonicalPrice`/`CanonicalDouble`/`CanonicalPercent`) was proposed as
the enforcement mechanism.

### Proposed `RiskPlan` struct

```cpp
struct RiskPlan
{
   string risk_plan_schema_version;
   string risk_plan_id;
   string candidate_id;
   string candidate_hash;
   string risk_context_hash;

   double planned_entry;
   double planned_sl;
   double planned_tp;

   double stop_distance_points;
   double rr_ratio;

   double risk_percent;
   double risk_amount;
   double lot_size;

   string sizing_method;
   string sizing_rules_version;

   string plan_hash;
};
```

### Proposed `plan_hash` payload (decision-bearing only)

`candidate_id`, `candidate_hash`, `risk_context_hash`, `planned_entry`,
`planned_sl`, `planned_tp`, `risk_percent`, `risk_amount`,
`stop_distance_points`, `rr_ratio`, `sizing_method`,
`sizing_rules_version`. Explicitly excludes debug text, labels,
timestamps, QA notes, runtime counters — same "content-only, no
metadata" discipline B6.2's `row_hash`/`dataset_hash` already proved
out (excludes `export_time`).

### Proposed entry point

```cpp
bool Candidate_ToRiskPlan(
   const TradeCandidate &candidate,
   const RiskContext &ctx,
   RiskPlan &outPlan
);
```

Proposed steps: validate input → derive normalized planned prices →
compute stop distance/RR → compute risk amount → compute `lot_size` →
stamp `risk_plan_id` → build canonical `plan_hash` → return pure
output only (no event append, no broker call, no order interaction).

### `lot_size` inclusion question — proposal recommends including it now

The proposal argues for computing `lot_size` (full sizing, no side
effects) in the SAME phase that builds `RiskPlan`, rather than
splitting sizing across two later phases — reasoning: if a later phase
re-derives `lot_size` from the same inputs, any drift between the two
derivations becomes a silent correctness bug rather than a structural
guarantee. Whether this repo's actual B7/B8 phase split should follow
that shape is a decision for whoever formally kicks off B7 — noted
here, not decided.

### Proposed QA gate (for whichever phase actually implements this)

- Same candidate + same risk context → identical `risk_plan_id`.
- Same candidate + same risk context → identical `plan_hash`.
- Repeated rebuild/replay (proposal suggested 10,000 runs, modeled on
  B3.5's repeated-rebuild determinism gate) → zero mismatches.
- Different balance/equity → changes sizing OUTPUTS only, never
  `risk_plan_id`.
- `candidate_hash` copied through unchanged, never recomputed.
- No broker interaction, no order interaction, no event emission.
- Input objects (`candidate`, `ctx`) unchanged after the call.
- Same `risk_plan_id` + a DIFFERENT `plan_hash` is an integrity-drift
  case for whichever phase does registry/replay work on `RiskPlan`
  (the `risk_plan_id`-vs-`plan_hash` split is exactly what makes this
  distinction possible to detect at all) — not a normal "identity
  changed" case.

## Why this was deferred, not implemented

B6's own kickoff message (verbatim, from earlier in this project):
*"B6 ไม่ใช่ phase สำหรับทำให้ระบบ 'เทรดเก่งขึ้น' แต่เป็น phase สำหรับตอบด้วยข้อมูลว่า
CRT_V1 สร้าง candidate แบบเชื่อถือได้..."* with an explicit prohibition list
including "no RiskPlan/position sizing" by name. `RiskPlan`/`lot_size`/
`risk_amount`/`plan_hash` is precisely that. B6.3 (hash contract spec +
mutation sweeps + structured rejection-reason classification) stays
scoped to what it already covers; this document exists so the design
work above isn't lost before B7 formally opens.
