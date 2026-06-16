# grill-me Report

Feature ID:
Reviewer:
Source: grill-me | manual-grill | claude | codex
Status: open | answered | accepted-risk

## Summary

One paragraph summary of the strongest concerns.

> **Note:** Design decisions (scale, style, tech stack, scope, user role) are handled in Gate 1
> by the human. grill-me is agent territory — it attacks technical risks only. Do not reopen
> settled design choices here.

## Challenge Questions

### Edge Cases

- What happens when inputs are empty, duplicated, malformed, stale, or too large?
- What happens on retry, refresh, cancel, undo, or partial failure?
- What happens under concurrent edits or repeated submissions?

### Security And Privacy

- Who can do this action?
- What data is exposed to logs, analytics, browser, model context, or third-party APIs?
- Can prompt injection or untrusted content influence privileged actions?

### Data And Migration

- Is existing data compatible?
- Is rollback possible after partial migration?
- Are derived/cache/indexed states invalidated?

### Performance And Scale

- What is the worst expected input size?
- What are the latency-sensitive paths?
- Can the implementation degrade gracefully?

### Testing

- What test would fail if the core promise is broken?
- What test would catch a permission or migration bug?
- What manual check is still needed?

## Findings

| ID | Severity | Finding | Required response | Status |
|---|---|---|---|---|
| G1 | P1 | | | open |

## Spec Amendments Needed

- 

## Accepted Residual Risks

| Risk | Why accepted | Owner | Review date |
|---|---|---|---|
| | | | |

