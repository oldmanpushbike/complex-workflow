# Codex ↔ Claude Complex Project Workflow (Bidirectional)

This package is a repo-portable workflow for complex AI-assisted software projects.
It supports **two orchestration modes** with a shared fallback matrix — Codex and Claude
Code can both lead, and both can challenge. When one side is unreachable, the other
completes the work locally without skipping gates.

## Operating Model

Every meaningful feature follows this trunk:

```text
OpenSpec → grill-me → find skill → implementation → dual review → verification
```

For complex projects, treat this as the main trunk. Individual task cards may
branch into parallel workstreams, but every branch must rejoin at review and
verification before it is considered complete.

## Two Modes, One Contract

### Mode A: Codex Orchestrates

```text
Codex: OpenSpec → grill-me(Claude) → skill-router → implement → review(Claude) → verify → ADR/retro
Claude: architecture challenger, code reviewer, fallback implementer
```

Start from Codex:

```text
Use AGENTS.md as the shared workflow contract. Start a new feature using the
Codex + Claude workflow. First create or update the OpenSpec proposal, then run
grill-me questioning, then build a task-skill map, then implement only approved
tasks. If Claude Code is available through MCP or CLI, ask it for architecture
review before implementation and code review after implementation. If Claude is
unavailable, follow workflow/fallback-matrix.md and continue in single-agent mode.
```

### Mode B: Claude Orchestrates

```text
Claude: OpenSpec → grill-me(Codex) → skill-router → implement → review(Codex) → verify → ADR/retro
Codex: architecture challenger, code reviewer, fallback implementer
```

Start from Claude Code:

```text
Read CLAUDE.md and AGENTS.md. Follow the Codex + Claude workflow. You are the
orchestrator. Create the OpenSpec proposal, send it to Codex for grill-me challenge,
build the task-skill map, implement approved tasks, and send implementation to Codex
for review. If Codex is unreachable, follow workflow/fallback-matrix.md and continue
in single-agent mode.
```

## Roles (Symmetric)

| Capability | Codex | Claude Code |
|---|---|---|
| Orchestrator | Mode A default | Mode B default |
| OpenSpec author | ✓ | ✓ |
| grill-me challenger | ✓ | ✓ |
| Skill router | ✓ | ✓ |
| Implementer | Primary (Mode A) | Fallback; primary (Mode B) |
| Architecture reviewer | Fallback | Primary |
| Code reviewer | ✓ | ✓ |
| Verifier | ✓ | ✓ |

Either agent can fill any role. The orchestrator is whoever starts the feature.

## Cross-Agent Communication

Agents communicate through three channels, tried in order:

1. **MCP** (preferred) — real-time tool calls between agents
2. **CLI** — invoke the other agent via shell, capture output
3. **Handoff files** — write to `workflow/handoffs/`, read by the other agent next session

If all three channels fail, the active agent enters **single-agent mode** (see Fallback).

## Fallback: When The Other Agent Is Unreachable

This is the core resilience rule. Do NOT stop when the other agent can't be reached.

```
Other unreachable → single-agent protocol → mark reviews single-agent → handoff for later
```

Detailed matrix: `workflow/fallback-matrix.md`

Quick reference:

| Situation | Action |
|---|---|
| Can't reach other for grill-me | Run grill-me yourself, mark `source: manual-grill` |
| Can't reach other for review | Self-review with switch-hats protocol, mark `single-agent` |
| Can't reach other for verification | Verify yourself, record residual risk |
| Other agent returns | Read handoff, review delta since last checkpoint |

The escape hatch (when even single-agent mode is stuck):

```text
human decision + recorded debt + smallest reversible next step
```

## Required Artifacts

Every feature should create or update these files under `workflow/`:

```text
workflow/templates/01-openspec-proposal.md
workflow/templates/02-grill-me-report.md
workflow/templates/03-task-skill-map.md
workflow/templates/04-implementation-plan.md
workflow/templates/05-verification-log.md
workflow/templates/06-adr.md
workflow/templates/07-task-retro.md
workflow/reviews/codex-review.md
workflow/reviews/claude-review.md
workflow/handoffs/codex-to-claude.md
workflow/handoffs/claude-to-codex.md
```

For a real project, copy these templates into a feature folder such as:

```text
workflow/features/2026-06-13-user-auth/
```

## Bootstrap Sequence

When a human or agent starts work, use this order:

1. Read this `README.md` for the project workflow overview.
2. Read `AGENTS.md` for the shared contract and hard gates.
3. Tool-specific startup:
   - **Codex orchestrating:** read `AGENTS.md` and active feature artifacts.
   - **Claude orchestrating:** read `CLAUDE.md`, then `AGENTS.md`.
   - **Codex challenging:** read `CODEX.md`, proposal, and handoff from Claude.
   - **Claude challenging:** read `CLAUDE.md`, proposal, and handoff from Codex.
4. Check `workflow/fallback-matrix.md` before declaring any tool failure blocking.
5. Check the active feature folder for the latest handoff.
6. Confirm current state from `workflow/state-machine.md`.

Ready criteria:

- active feature id is known
- orchestrator is identified
- current state is known
- last verified checkpoint is known
- unavailable tools/agents are recorded
- next gate is explicit

## Safety Rules

- No implementation begins until the OpenSpec artifact has explicit acceptance criteria.
- No task may change requirements silently during implementation.
- Any spec gap discovered during coding returns to grill-me or OpenSpec before continuing.
- Cross-agent reviews focus on correctness, security, migration risk, test gaps, and scope drift.
- If both agents disagree, the spec wins. If the spec is ambiguous, stop and amend the spec.

## Long-Running Project Rules

- Use ADRs for architecture decisions that affect more than one task.
- Add a retro entry after each completed task.
- Keep task branches independent until review.
- Merge branches only through the verification log.
- Do not let chat memory become the only place a decision exists.
