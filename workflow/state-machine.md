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

## Failure Rollback Paths

Every Gate carries an explicit rollback path. When a gate check fails or a state
discovers upstream defects, the state machine defines exactly where to return:

```text
                    ┌─────────── [ 回退 ] ───────────┐
                    │                                │
S0 → S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8 → S9
 ↑    ↑    ↑    ↑    ↑    ↑    ↑    ↑    │    │
 │    │    │    │    │    │    │    │    │    │
 │    └────┼────┼────┼────┼────┼────┼────┘    │
 │         │    │    │    │    │    │          │
 │         └────┼────┼────┼────┼────┘          │
 │              │    │    │    │               │
 └──────────────┴────┴────┴────┴───────────────┘
           经验反馈弧 (Retro → OpenSpec)
```

### Rollback Decision Table

| From | Trigger | Rollback To | Rationale | Scope |
|---|---|---|---|---|
| **S2** grill-me | grill-me reveals fundamental spec gaps that cannot be answered without revising goals | **S1** | Proposal is underspecified — answering challenges requires rewriting OpenSpec | Trunk |
| **S2** grill-me | challenger unreachable, manual grill incomplete | **S2** (retry) | Remain in S2 with manual grill template; see `feedback-loop.md` 2.3 | Trunk |
| **S3** spec amendment | Gate 2 failure (grill-me report missing or P0/P1 unresolved) | **S3** (retry) | Remain in S3; inject feedback per `feedback-loop.md` Chapter 2 | Trunk |
| **S3** spec amendment | grill-me uncovers deeper spec contradictions requiring goal-level rethink | **S1** | Amending the proposal is insufficient — goals themselves are contradictory | Trunk |
| **S5** implementation | Gate 4 failure (implementation plan missing, scope drift) | **S5** (retry) | Remain in S5; inject feedback per `feedback-loop.md` 2.3 | Branch or trunk |
| **S5** implementation | implementation exposes spec ambiguity — task cannot be completed as written | **S3** | Spec is ambiguous; implementation should not guess. See dispatcher fallback `agent_disagreement` | Branch |
| **S6** dual review | Gate 5 failure (reviews missing or incomplete) | **S6** (retry) | Remain in S6; inject feedback per `feedback-loop.md` 2.3 | Branch or trunk |
| **S6** dual review | both reviews flag same P0 → halt + human sign-off | **S3** or human decision | If root cause is spec ambiguity, return to S3. If root cause is implementation error, return to S5. Human decides. | Branch |
| **S6** dual review | `agent_disagreement` fallback — reviewers disagree on severity and spec is ambiguous | **S3** | Spec wins rule triggers spec amendment. See `fallback-matrix.md` Agent Disagreement row. | Trunk if shared spec affected |
| **S7** verification | Gate 6 failure (verification log missing) | **S7** (retry) | Remain in S7; inject feedback per `feedback-loop.md` 2.3 | Branch or trunk |
| **S7** verification | acceptance criterion fails verification | **S5** (if implementation bug) or **S3** (if criterion is wrong) | Human waives or directs rollback. See dispatcher human routing table. | Branch |
| **S8** knowledge capture | Gate 7 failure (ADR or retro missing) | **S8** (retry) | Remain in S8; inject feedback per `feedback-loop.md` 2.3 | Trunk |
| **S8** knowledge capture | closure check fails (experience not written to pipeline) | **S8** (retry) | Gentle reminder — does not consume retryCount. See `feedback-loop.md` 5.3. | Trunk |
| **Any branch** | branch gate failure exhausts retries | **Branch paused**; trunk continues | Other branches not blocked unless shared spec is affected. See `feedback-loop.md` 4.3. | Branch only |
| **Any branch** | branch failure exposes shared spec problem | **S3** (all branches reassess) | Shared spec amendment may require partial rollback of unaffected branches. See `feedback-loop.md` 4.3. | Trunk + all branches |

### Rollback Rules

1. **Rollback scope matches root cause.** If the failure is branch-specific (e.g., Branch A's tests fail), only Branch A rolls back. If the failure is spec-level (e.g., goals are contradictory), the entire trunk rolls back to S3 or S1.
2. **Rollback does not discard audit trail.** Every rollback writes a `stateHistory` entry with `trigger: "rollback"`, preserving the reason and scope.
3. **Rollback to S1 is rare and requires human confirmation.** It means the OpenSpec goals themselves need rewriting.
4. **Gate retries (same-state rollback) follow `feedback-loop.md` Chapter 2.** Gate failures with retryCount < maxRetries are handled by feedback injection within the same state. Only exhausted retries or root-cause rollbacks change state.
5. **Rollback resets affected gates.** When rolling back from S6 to S3, gates 4–5 are reset to `pending`. Gates 1–3 (which were passed before the rollback) are re-validated.

---

## Retro-to-OpenSpec Feedback Arc (S8 → S0)

The longest feedback arc in the state machine runs from **S8 Knowledge Capture**
back to **S0 Intake / S1 OpenSpec Draft** of **future** features. This is the
experience-driven learning loop that ensures every feature makes the next one smarter.

```text
功能 A: S0 → S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8 → S9
                                                      │
                                          S8 Retro 产出：
                                          - ADR (06-adr.md)
                                          - Task Retro (07-task-retro.md)
                                          - feedbackLoop.branchSummary
                                                      │
                                          dispatcher 写入经验管道
                                          workflow/experience/
                                            ├── lessons/
                                            ├── patterns/
                                            └── instincts/
                                                      │
功能 B: S0 ← 经验管道加载 ←──────────────────────────┘
         │
         ↓
        S1 OpenSpec 撰写时必须：
        1. 查阅相关 ADR（架构决策复用或反模式规避）
        2. 在提案「经验参考」章节引用至少一条相关教训
        3. 无相关教训时写「本次无直接相关经验记录」
```

### Feedback Arc Channels

Four channels carry experience from Retro to future OpenSpec. See `feedback-loop.md` Chapter 5 for the detailed protocol.

| Channel | Writer (S8) | Reader (S0/S1) | Artifact |
|---|---|---|---|
| **ADR** | Architecture decisions, especially those triggered by feedback-loop escalation | Future S1: check for reusable decisions or anti-patterns to avoid | `06-adr.md` |
| **Task Retro** | Per-task stats: which gate failed most, which fix worked, process improvement suggestions | Future S4: optimize task-skill mapping based on historical failure patterns | `07-task-retro.md` |
| **Experience Pipeline** | Concrete lessons (`lessons/`), cross-feature patterns (`patterns/`), orchestrator instincts (`instincts/`) | Future S0: dispatcher scans for keyword matches; S1: cited in proposal | `workflow/experience/` |
| **Branch Summary** | Aggregated per-branch feedback stats (total retries, most-failed gate, common failure pattern) | Future S4: dispatcher attaches `risk: high-gate-failure` to tasks whose gate historically fails | `feedbackLoop.branchSummary` |

### Arc Closure Check

At S8 exit, the dispatcher verifies the arc is closed (see `feedback-loop.md` 5.3):

1. `07-task-retro.md` contains a "Feedback Loop Statistics" section.
2. New experience has been written to at least one of `lessons/`, `patterns/`, or `instincts/` (or an explicit "no new patterns" note is recorded).
3. `feedbackLoop.branchSummary` has been generated.

If any of these are missing, Gate 7 is marked incomplete. The orchestrator supplements
before advancing to S9. **No Retro leaves without an artifact.** Every feature's
failure experience must become the next feature's leverage.

---

## Branch-Level State Tracking

When S4 produces parallel branches, each branch carries its own state slice.
The trunk-level `currentState` reflects the **slowest** active branch (or the merge
state once all branches converge).

### Branch State Fields

Each entry in `branchTasks[]` within `feature-state.json` tracks:

| Field | Type | Description |
|---|---|---|
| `branchId` | string | Unique branch identifier, e.g. `"branch-A"`, `"branch-frontend"` |
| `label` | string | Human-readable branch name, e.g. `"Frontend Search Component"` |
| `status` | enum | `pending` \| `in_progress` \| `completed` \| `paused` \| `rolled_back` |
| `currentState` | enum | The branch's own S-state (`S5`, `S6`, or `S7`). Branches only inhabit S5–S7; S0–S4 and S8–S9 are trunk-only. |
| `orchestrator` | string | Agent executing this branch (`codex` \| `claude`). May differ from trunk orchestrator if work is delegated. |
| `dependsOn` | string[] | Other `branchId`s this branch must wait for before merging. Empty if independent. |
| `feedbackLoop` | object | Branch-isolated feedback loop state. See `feedback-loop.md` 4.2 for full schema. |
| `stateHistory` | array | Branch-level state transitions (S5↔S6↔S7, rollbacks within branch). |
| `artifacts` | object | Paths to branch-specific artifacts (e.g., sub-directory under `reviews/`). |

### Branch State Rules

1. **Independent progression.** Branch A moving S5→S6 does not require Branch B to leave S5. Each branch advances at its own pace.
2. **Gate isolation.** Branch A's Gate 4 failure increments Branch A's `feedbackLoop.retryCount`. Branch B's counters are unaffected. See `feedback-loop.md` 4.3 for the failure handling matrix.
3. **Merge gate.** All branches must reach S7 (completed) before the trunk can advance S7→S8. If any branch is `paused` (exhausted retries, awaiting human), the merge is blocked.
4. **Shared spec impact.** If any branch's failure reveals a shared spec problem, the dispatcher pauses all branches and rolls the trunk back to S3. Each branch then reassesses whether it needs partial rollback.
5. **Branch state does not outlive merge.** After S8 merge, branch-level `currentState` and `feedbackLoop` are archived into `branchSummary`. The trunk `currentState` becomes the authoritative state.
6. **Branch-level rollback scope.** A branch rollback (e.g., Branch A S7→S5) only resets that branch's gates (4–6). Other branches are untouched unless they declare `dependsOn` the rolled-back branch.

### Example: Branch State in feature-state.json

```json
{
  "branchTasks": [
    {
      "branchId": "branch-frontend",
      "label": "前端搜索组件",
      "status": "in_progress",
      "currentState": "S6",
      "orchestrator": "codex",
      "dependsOn": [],
      "feedbackLoop": {
        "retryCount": 1,
        "maxRetries": 3,
        "lastFailureGate": "gate-4",
        "feedbackInjected": true,
        "feedbackSummary": "补充了 Jest 测试计划章节"
      },
      "stateHistory": [
        { "from": "S5", "to": "S5", "trigger": "feedback-loop-rollback",
          "notes": "Gate 4 失败，retryCount=1，修正后重试" },
        { "from": "S5", "to": "S6", "trigger": "gate-pass",
          "notes": "Gate 4 通过，进入双审" }
      ]
    },
    {
      "branchId": "branch-backend",
      "label": "后端 API 端点",
      "status": "completed",
      "currentState": "S7",
      "orchestrator": "claude",
      "dependsOn": [],
      "feedbackLoop": { "retryCount": 0, "maxRetries": 3 }
    }
  ]
}
```

---

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

**Ask human if:** feature description is ambiguous. No existing mechanism fires at S0.
OpenSpec Draft

Input:

- intake notes
- repo evidence

Output:

- `01-openspec-proposal.md`

Exit criteria:

- goals, non-goals, acceptance criteria, and verification plan exist

Design trade-offs and downstream contract implications are captured in the OpenSpec
Open Questions and Decision Log — no separate human ask. Grill-me (S2) surfaces
architectural conflicts.

**Experience check (S0→S1):** During S0→S1 transition, the dispatcher scans
`workflow/experience/` for keyword-matching lessons from past features. The
orchestrator must cite at least one relevant lesson in the proposal's "经验参考"
section, or explicitly note "本次无直接相关经验记录". This is the intake end of
the Retro→OpenSpec feedback arc. See [Retro-to-OpenSpec Feedback Arc](#retro-to-openspec-feedback-arc-s8--s0) above.

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

P0 risks and goal-level challenges are handled by grill-me's built-in Required
Response and Accepted Residual Risks sections — no separate human ask.

**Rollback path:** If grill-me reveals fundamental spec gaps that cannot be answered
without revising goals, rollback to **S1**. If challenger is unreachable, remain in
S2 with manual grill (see `fallback-matrix.md` Scenario 1/3).

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

Agent disagreements are resolved by the decision rule: spec wins; if ambiguous,
amend spec.

**Rollback paths:**
- Gate 2 failure (grill-me report missing or P0/P1 unresolved) → remain in **S3** (retry with feedback injection per `feedback-loop.md` 2.3).
- Deeper spec contradictions requiring goal-level rethink → rollback to **S1** (rare; requires human confirmation).
- `agent_disagreement` fallback where spec is ambiguous → return to **S3** to amend (resolved within S3; does not roll back further unless spec proves unamendable).

Task + Skill Map

Input:

- accepted proposal
- accepted risks

Output:

- `03-task-skill-map.md`

Exit criteria:

- every task has owner, skill route, likely files, tests, rollback note
- independent branches are identified when parallel work is safe

**Ask human if:** a task requires domain expertise neither agent has, or touches
production data/billing/auth/deployment credentials.

**Branch initialization:** At S4 exit, the dispatcher initializes `branchTasks[]`
in `feature-state.json` with per-branch `feedbackLoop`, `currentState`, and
`stateHistory` fields. See [Branch-Level State Tracking](#branch-level-state-tracking) above.

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

**Ask human if:** a task takes >2x estimated effort in the task map. (Requirement
gaps found during implementation are handled by Superpowers escalation or the
Implementation Plan's Spec Gaps Found table — no separate human ask.)

**Rollback paths:**
- Gate 4 failure (implementation plan missing, scope drift) → remain in **S5** (retry with feedback injection per `feedback-loop.md` 2.3).
- Implementation exposes spec ambiguity — task cannot be completed as written → rollback to **S3** (branch-level if branch-specific; trunk-level if shared spec affected).
- Branch-level only: other branches continue while the affected branch retries. See `feedback-loop.md` 4.3.

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

Both reviews flagging the same P0 is a process rule (halt + human sign-off), not a
separate trigger. Agent disagreements on severity are resolved by the spec/amend rule.

**Rollback paths:**
- Gate 5 failure (reviews missing or incomplete) → remain in **S6** (retry with feedback injection per `feedback-loop.md` 2.3).
- Both reviews flag same P0 → halt + human sign-off. Human decides: **S3** (if spec is wrong) or **S5** (if implementation is wrong).
- `agent_disagreement` on severity + ambiguous spec → rollback to **S3** (trunk-level if shared spec affected; branch-level otherwise).
- `reviewer_unreachable` → orchestrator runs single-agent review protocol, remain in S6.

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

**Rollback paths:**
- Gate 6 failure (verification log missing) → remain in **S7** (retry with feedback injection per `feedback-loop.md` 2.3).
- Acceptance criterion fails verification → human decides: **S5** (implementation bug) or **S3** (criterion is wrong). See dispatcher human routing table.
- All branches must pass S7 before trunk advances to S8. A single branch's S7 failure blocks the merge. See [Branch-Level State Tracking](#branch-level-state-tracking) rule 3.

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

ADR irreversibility is handled by the ADR template's Revisit Trigger field — no
separate human ask unless no plausible revisit trigger can be identified.

**Feedback arc closure:** At S8, the dispatcher executes the closure check defined
in `feedback-loop.md` 5.3: task retros include feedback statistics, new experience
is written to the pipeline, and `branchSummary` is generated. This ensures the
Retro→OpenSpec feedback arc is complete. See [Retro-to-OpenSpec Feedback Arc](#retro-to-openspec-feedback-arc-s8--s0) above.

**Branch feedback aggregation:** Before S8→S9 transition, the dispatcher aggregates
all `branchTasks[].feedbackLoop` data into `feedbackLoop.branchSummary`. This
summary is a key input to `07-task-retro.md`. See `feedback-loop.md` 4.4.

**Rollback path:**
- Gate 7 failure (ADR or retro missing) → remain in **S8** (retry with feedback injection per `feedback-loop.md` 2.3).
- Closure check failure (experience not written) → remain in **S8** (gentle reminder; does not consume retryCount).

Archive / Merge

Input:

- verified feature folder

Output:

- PR summary, release note, or archive note

Exit criteria:

- final artifact set is coherent and discoverable

---

## Collaboration with dispatcher.md

The state machine and the dispatcher are separate concerns with a strict boundary.
This section defines how they collaborate.

### Responsibility Boundary

```
state-machine.md（本文件）负责：
  ✅ 定义所有合法状态（S0–S9）及其含义
  ✅ 定义状态转换的 Exit Criteria（门禁条件）
  ✅ 定义 Rollback Paths（失败回退路径）
  ✅ 定义 Retro→OpenSpec Feedback Arc（经验反馈弧）
  ✅ 定义 Branch-Level State Tracking 字段和规则

dispatcher.md（workflow/dispatcher.md）负责：
  ✅ 读取 feature-state.json 确定当前状态
  ✅ 在每次状态转换前调用 gate-check.sh
  ✅ 对照本文件判断下一个合法状态
  ✅ 根据当前状态和 Agent 角色生成路由指令
  ✅ 管理 feedbackLoop（重试、注入修正、触发人类 Checkpoint）
  ✅ 检测 Agent 回归并触发交叉验证
  ✅ 执行状态一致性校验（JSON vs 文件系统）

两者互不越界：
  ❌ state-machine.md 不做路由决策（那是 dispatcher 的事）
  ❌ dispatcher 不重新定义状态含义（那是 state-machine.md 的事）
  ❌ state-machine.md 不管理重试策略（那是 feedback-loop.md 的事）
  ❌ dispatcher 不做产物检查（那是 gate-check.sh 的事）
```

### State Machine as Dispatcher's Rulebook

The dispatcher reads this file as its canonical rulebook. Every routing decision
the dispatcher makes must trace back to a transition defined here. Specifically:

| Dispatcher Action | State Machine Reference |
|---|---|
| "Advance S1→S2" | S1 Exit Criteria + Gate 1 |
| "Remain in S2 (manual grill)" | S2 Fallback: `challenger_unreachable` |
| "Rollback S6→S3" | [Failure Rollback Paths](#failure-rollback-paths): both reviews flag same P0, root cause is spec ambiguity |
| "Block merge until all branches S7" | [Branch-Level State Tracking](#branch-level-state-tracking) rule 3 |
| "Trigger Retro→OpenSpec arc" | [Retro-to-OpenSpec Feedback Arc](#retro-to-openspec-feedback-arc-s8--s0): S8 closure check |
| "Pause branch (retries exhausted)" | [Failure Rollback Paths](#failure-rollback-paths): branch gate failure exhausts retries |
| "Rollback trunk S5→S3 (shared spec)" | [Failure Rollback Paths](#failure-rollback-paths): branch failure exposes shared spec problem |

### Dispatcher State Machine Loading

The dispatcher loads this file at session start (see `dispatcher.md` Step 0). It
parses:

1. The legal state enum (S0–S9).
2. The valid transitions from the current state.
3. The rollback paths available from the current state.
4. The branch merge conditions (whether all branches have converged).

The dispatcher does not infer transitions — it reads them from this file. If a
transition is not documented here, the dispatcher must reject it and flag an
`invalid_transition` error.

### Gate Check Integration Point

The dispatcher calls `gate-check.sh` at every state transition. The state machine
defines **which gate** corresponds to **which transition**. See `dispatcher.md`
Section 3 for the complete state→gate mapping table.

---

## Cross-Reference: feedback-loop.md

The feedback loop is the adaptive correction layer that sits **inside** the state
machine. It is not a separate state — it is an embedded mechanism activated when
any gate check fails. Key integration points:

| State Machine Concept | feedback-loop.md Reference |
|---|---|
| Gate failure → same-state retry | Chapter 2: Core Loop (失败→注入→回退→重试) |
| retryCount >= maxRetries → human escalation | Chapter 3: Retry Limits & Escalation |
| Branch-level feedback isolation | Chapter 4: Branch-Level Retries |
| S8 Retro → S0 OpenSpec learning arc | Chapter 5: Retro→OpenSpec Learning Feedback Arc |
| dispatcher reads feedbackLoop fields | Chapter 6: Collaboration with dispatcher.md |
| feedbackLoop JSON schema | Chapter 7: Complete Schema |
| State↔Gate↔Feedback behavior table | Chapter 8: State Machine Cross-Reference |
| Stuck detection (stalledSince >= 48h) | Chapter 9: Fault Modes & Recovery |

When a gate check fails:
1. The dispatcher reads `feedbackLoop.retryCount` from `feature-state.json`.
2. If `retryCount < maxRetries`, the dispatcher routes to the feedback injection protocol (`feedback-loop.md` 2.3).
3. If `retryCount >= maxRetries`, the dispatcher triggers the human escalation protocol (`feedback-loop.md` 3.3).
4. The state machine's rollback path determines **which state** to return to; the feedback loop determines **how** to fix the failure before retrying.

### Quick Reference: Which file answers which question

| Question | Answer in |
|---|---|
| "What state am I in?" | `feature-state.json` → `currentState` |
| "What state comes next?" | `state-machine.md` (this file) → state exit criteria |
| "Can I advance?" | `gate-check.sh` → PASS/FAIL |
| "What do I do if gate check fails?" | `feedback-loop.md` → Chapter 2 or 3 |
| "Who should do the work?" | `dispatcher.md` → routing tables |
| "What if the other agent is gone?" | `fallback-matrix.md` → scenario tables |

---

## Related Documents

| Document | Role |
|---|---|
| `workflow/dispatcher.md` | Routing engine — reads this state machine, enforces transitions, manages feedback loops |
| `workflow/feedback-loop.md` | Adaptive correction layer — gate failure retry protocol, branch isolation, Retro→OpenSpec arc details |
| `workflow/fallback-matrix.md` | Capability degradation — what to do when agents/tools/channels are unavailable |
| `workflow/learning-checkpoints.md` | Human interaction format — the six-section checkpoint structure used for escalations |
| `workflow/feature-state.schema.json` | JSON Schema for `feature-state.json` — canonical field definitions |
| `workflow/scripts/gate-check.sh` | Deterministic gate checker — zero-LLM file existence and structure validation |
| `workflow/experience/pipeline.md` | Experience pipeline — how lessons flow from Retro back into future features |
