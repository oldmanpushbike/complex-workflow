# find skill Router

Use this when an explicit find-skill tool is unavailable.

## Input

- accepted OpenSpec proposal
- grill-me report
- task description
- repo context

## Routing Questions

1. What domain does this task primarily belong to?
2. What failure mode would be expensive?
3. Does the task require deterministic tooling?
4. Does it touch security, auth, data migration, billing, deployment, or user data?
5. Does the codebase already contain a local skill or pattern for this domain?

## Routing Table

| Domain | Preferred skill | Fallback |
|---|---|---|
| UI implementation | frontend/design skill | Codex implementation + browser verification |
| API design | backend/API skill | Claude architecture review + Codex implementation |
| Database migration | database skill | Stop for human review if production data is affected |
| Auth/security | security skill | Stop for human review on P0/P1 risk |
| Tests | ai-test-automation skill | Codex writes focused tests |
| Performance | performance profiling skill | Static review + targeted benchmark |
| Docs/spec | docs or OpenSpec skill | Manual template completion |
| Deployment | DevOps skill | Stop if credentials or production changes are required |

## Output

Write one row per task into `03-task-skill-map.md`.

Required fields:

- selected skill
- reason
- allowed tools
- forbidden tools
- expected output
- fallback implementer

