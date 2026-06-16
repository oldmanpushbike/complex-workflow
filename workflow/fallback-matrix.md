# Fallback Matrix

The workflow degrades by replacing capabilities, not by skipping gates.

## Primary Fallback Table

| Failure | Primary fallback | Target state | Required artifact note | Stop condition |
|---|---|---|---|---|
| OpenSpec unavailable | Fill `01-openspec-proposal.md` manually | S1 | Mark `source: manual-openspec` | Stop only if goals or acceptance criteria are unknown |
| grill-me unavailable | Use `02-grill-me-report.md` questions manually | S2 | Mark `source: manual-grill` | Stop if unresolved P0/P1 risk affects safety or data |
| find skill unavailable | Use `workflow/skills/find-skill-router.md` | S4 | Mark `skill_route: manual` | Stop if task requires unavailable domain expertise |
| Superpowers unavailable | Orchestrator implements from task map | S5 | Mark `implementer: <orchestrator>` | Stop if orchestrator lacks required tool permissions |
| Codex unreachable (Claude orchestrates) | Claude runs full single-agent protocol | S2–S7 | Mark `codex_status: unreachable`, reviews `single-agent` | Stop if verification requires Codex-only environment |
| Claude unreachable (Codex orchestrates) | Codex runs full single-agent protocol | S2–S7 | Mark `claude_status: unreachable`, reviews `single-agent` | Stop if architecture risk is high and no human review exists |
| MCP unavailable | Use CLI or handoff files | current state | Record `mcp_status: down` | Stop only for private data/tool access that cannot be substituted |
| Network unavailable | Use local docs, repo context, and explicit assumptions | current state | Mark docs as `offline` | Stop if current external API behavior is required |
| Tests unavailable | Use static review plus manual reproduction plan | S7 | Explain why tests could not run | Stop if change is high-risk production logic |
| Agent disagreement | Spec wins; if ambiguous, amend spec | S3 | Record disagreement and resolution | Stop until spec is clarified |
| Orchestrator unreachable (challenger active) | Challenger assesses checkpoint and either reviews delta or reverts | last verified checkpoint | Record `orchestrator_status: unreachable`, write takeover handoff | Stop if work cannot be assessed without orchestrator context |
| Human unavailable (escape hatch triggered) | Wait timeout → document → smallest reversible step → ADR | current state | Mark `needs-human-review` | Stop only if no reversible step exists AND no escalation contact |
| Multiple tool failures | Reduce to one-agent protocol | current state | Record unavailable tools | Stop only if no reversible next step exists |

## Cross-Agent Unreachability (Detailed)

This is the most common degradation. When the orchestrator cannot reach the other agent:

### Scenario 1: Claude unreachable during grill-me (Codex orchestrates)

```
Codex: fill 02-grill-me-report.md manually
Mark: source=manual-grill, claude_status=unreachable
Continue to S3 with self-answered challenges
Risk: missing Claude's architecture skepticism → compensate with extra self-review in S6
```

### Scenario 2: Claude unreachable during review (Codex orchestrates)

```
Codex: switch-hats self-review
Mark: review_mode=single-agent, claude_status=unreachable
Use the same review template, mark every finding as single-agent
Write handoff: workflow/handoffs/codex-to-claude.md for later verification
```

### Scenario 3: Codex unreachable during grill-me (Claude orchestrates)

```
Claude: fill 02-grill-me-report.md manually
Mark: source=manual-grill, codex_status=unreachable
Continue to S3 with self-answered challenges
Risk: missing Codex's implementation perspective → compensate with extra spec review
```

### Scenario 4: Codex unreachable during review (Claude orchestrates)

```
Claude: switch-hats self-review
Mark: review_mode=single-agent, codex_status=unreachable
Use the same review template, mark every finding as single-agent
Write handoff: workflow/handoffs/claude-to-codex.md for later verification
```

## Single-Agent Review Protocol

When only one agent is available:

1. Switch hats explicitly:
   - **Pass 1 — implementer:** Write the code to spec.
   - **Pass 2 — skeptic:** Read the diff. Try to break every assumption. Find every missing edge case. Use the same review templates that the missing agent would use: if Codex is missing, also fill `claude-review.md` sections (Architecture Findings, Risk Review). If Claude is missing, also fill `codex-review.md` sections (Spec Trace Check, Test Gap Check). Address every section, writing N/A with justification if a section does not apply.
   - **Pass 3 — verifier:** Run tests, check acceptance criteria, record residual risk.
2. Wait at least one **artifact boundary** between passes. An artifact boundary means: close the current session, start a fresh session, and re-read the artifacts (OpenSpec, task map, diff) as if seeing them for the first time. If starting a new session is impossible, write a handoff to yourself in `workflow/handoffs/self-review-handoff.md`, wait at least until the next calendar day, then read your own handoff as if from another agent. Do not review in the same context window as implementation.
3. Use the same review templates as dual-agent mode.
4. Mark every review as `single-agent` and list what the missing agent would normally catch.
5. **Self-approval safeguard:** If you find zero P0 or P1 issues in your own code, document at least three specific assumptions you are making and why each is safe. If you cannot identify three non-trivial assumptions, the review is incomplete — re-examine the diff with the missing agent's review template.
6. Write a handoff for the other agent to verify when they return.

## Orchestrator Unreachable Protocol

When the orchestrator becomes unreachable and the challenger is still active:

1. Read the latest state-machine.md, all feature artifacts, and any handoff files.
2. If the orchestrator left a handoff, follow it.
3. If no handoff exists, assess the last verified checkpoint:
   - **(a)** If work past the checkpoint appears complete and coherent, perform a full review of the delta and either approve or revert to the checkpoint.
   - **(b)** If work is partial or incoherent, revert to the last verified checkpoint, write an ADR explaining the decision, and notify the human.
4. Do not assume the orchestrator role unless explicitly asked by the human, or the human is unreachable and a decision is time-sensitive.
5. Write a handoff in `workflow/handoffs/claude-to-codex.md` (or `codex-to-claude.md`) documenting the takeover decision, rationale, and current state.
6. Record the event in the verification log with `orchestrator_status: unreachable`.

## Mid-Exchange Recovery

When MCP or CLI fails mid-conversation (not before the interaction started):

1. Save all answers received so far into a partial grill-me or review report marked `status: interrupted`.
2. Send only the unanswered items via the next available channel (CLI or handoff). Do not re-send already-answered items.
3. The challenger appends answers to the existing partial report.
4. If no channels remain (MCP down, CLI unavailable, handoff unacknowledged), enter single-agent mode but document which items were answered by the challenger vs. self-answered.
5. Add a `partial_grill` or `partial_review` fallback event to the state record.

## Human Unavailable Protocol

Use this when both the other agent and the human are unreachable:

1. Record the blocker and escape-hatch trigger in the verification log with timestamp.
2. Set a timeout (default 24 hours). Document it in the feature state file.
3. While waiting, document all reversible options and their risks. Select the smallest reversible next step in case the timeout expires.
4. If the timeout expires with no human response:
   - **(a)** Write an ADR documenting the unilateral decision and rationale.
   - **(b)** Execute the smallest reversible step.
   - **(c)** Mark the feature as `needs-human-review` in the feature state.
   - **(d)** Create a follow-up task explicitly requesting human review of the escaped decision.
5. If the project has a `workflow/ESCALATION_CONTACTS.md` file or contacts listed in the README, escalate to the secondary contact before taking unilateral action.

## Escape Hatch

Use this only when the matrix cannot move the task forward.

```text
human decision + recorded debt + smallest reversible next step
```

Required outputs:

- ADR if the decision affects architecture, data, security, workflow, or long-term maintenance.
- Verification log entry describing what could not be verified.
- Follow-up task for the missing capability or deferred review.

## Resume Protocol

When the unreachable agent returns:

1. Read the latest OpenSpec proposal.
2. Read the latest task map.
3. Read all handoff files written during the absence.
4. Review only the delta since the last verified checkpoint.
5. Focus on findings marked `single-agent` — these had no cross-check.
6. Do not restart the feature from scratch unless artifacts are contradictory.
