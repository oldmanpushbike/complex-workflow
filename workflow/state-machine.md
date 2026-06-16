# Workflow State Machine

Use this state machine for each feature. It is **orchestrator-agnostic** — the same
states and transitions apply whether Codex or Claude is leading.

```text
S0 Intake
  → S1 OpenSpec Draft
  → S2 grill-me Challenge
  → S3 Spec Amendment
  → S4 Task + Skill Map
  → S5 Implementation
  → S6 Dual Review
  → S7 Verification
  → S8 Knowledge Capture
  → S9 Archive / Merge
```

This is the trunk. After S4, tasks may branch:

```text
S4 Task + Skill Map
  → Branch A: S5 → S6 → S7
  → Branch B: S5 → S6 → S7
  → Branch C: S5 → S6 → S7
  → Merge: S8 Knowledge Capture → S9 Archive / Merge
```

Branches may not skip S6 or S7. A failed branch can return to S3 without forcing
all branches to restart unless the shared spec changes.

## Orchestrator Field

Every state transition records:

- `orchestrator: codex | claude` — who is leading this feature
- `challenger: codex | claude | manual | none` — who is doing grill-me/review
- `mode: dual-agent | single-agent` — whether the other agent is reachable

The orchestrator is set at S0 and does not change for the life of the feature.
The challenger and mode may change if the other agent becomes reachable/unreachable.

## S0 Intake

Input:

- user request
- existing repo context
- relevant docs or issues

Exit criteria:

- feature id chosen
- orchestrator identified
- proposal file created

**Ask human if:** feature description is ambiguous. No existing mechanism fires at S0. OpenSpec Draft

Input:

- intake notes
- repo evidence

Output:

- `01-openspec-proposal.md`

Exit criteria:

- goals, non-goals, acceptance criteria, and verification plan exist

Design trade-offs and downstream contract implications are captured in the OpenSpec Open Questions and Decision Log — no separate human ask. Grill-me (S2) surfaces architectural conflicts.

Fallback events:

- `openspec_unavailable` → manual proposal template, remain in S1

## S2 grill-me Challenge

Input:

- OpenSpec draft

Output:

- `02-grill-me-report.md`

Exit criteria:

- each challenge is answered, accepted, or escalated
- challenger recorded: `codex | claude | manual`

P0 risks and goal-level challenges are handled by grill-me's built-in Required Response and Accepted Residual Risks sections — no separate human ask.

Fallback events:

- `grill_unavailable` → manual grill template, remain in S2
- `challenger_unreachable` → orchestrator runs manual grill, mode becomes `single-agent`, remain in S2

## S3 Spec Amendment

Input:

- grill-me report

Output:

- revised proposal

Exit criteria:

- unresolved P0/P1 risks are either fixed or explicitly accepted

Agent disagreements are resolved by the decision rule: spec wins; if ambiguous, amend spec. Task + Skill Map

Input:

- accepted proposal
- accepted risks

Output:

- `03-task-skill-map.md`

Exit criteria:

- every task has owner, skill route, likely files, tests, rollback note
- independent branches are identified when parallel work is safe

**Ask human if:** a task requires domain expertise neither agent has, or touches production data/billing/auth/deployment credentials.

Fallback events:

- `find_skill_unavailable` → manual skill router, remain in S4

## S5 Implementation

Input:

- approved task map

Output:

- code changes
- `04-implementation-plan.md` updated with actual notes

Exit criteria:

- no unapproved task changes

**Ask human if:** a task takes >2x estimated effort in the task map. (Requirement gaps found during implementation are handled by Superpowers escalation or the Implementation Plan's Spec Gaps Found table — no separate human ask.)

Fallback events:

- `superpowers_unavailable` → orchestrator implements, remain in S5
- `orchestrator_cannot_implement` → challenger implements + handoff, remain in S5

## S6 Dual Review

Input:

- diff
- proposal
- task map

Output:

- `reviews/codex-review.md`
- `reviews/claude-review.md`

Exit criteria:

- P0/P1 fixed or explicitly deferred
- If `single-agent`, residual risk is explicitly recorded

Both reviews flagging the same P0 is a process rule (halt + human sign-off), not a separate trigger. Agent disagreements on severity are resolved by the spec/amend rule.

Fallback events:

- `reviewer_unreachable` → orchestrator runs single-agent review protocol, mode becomes `single-agent`, remain in S6
- `agent_disagreement` → return to S3 if spec is ambiguous

## S7 Verification

Input:

- final diff
- review findings

Output:

- `05-verification-log.md`

Exit criteria:

- tests/manual checks recorded
- residual risk recorded

**Ask human if:** verification fails on an acceptance criterion. Only the human can waive it.

Fallback events:

- `tests_unavailable` → static review plus manual check plan, remain in S7

## S8 Knowledge Capture

Input:

- final review
- verification log
- implementation notes

Output:

- ADRs for durable decisions
- task retros for lessons learned

Exit criteria:

- decisions are not trapped only in chat
- follow-up work is explicit

ADR irreversibility is handled by the ADR template's Revisit Trigger field — no separate human ask unless no plausible revisit trigger can be identified. Archive / Merge

Input:

- verified feature folder

Output:

- PR summary, release note, or archive note

Exit criteria:

- final artifact set is coherent and discoverable
