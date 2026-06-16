# Task Retro

Feature ID: 2026-06-13-ai-werewolf
Date: 2026-06-13
Mode: single-agent (Codex unavailable)

## What Went Well

1. **OpenSpec → grill-me split worked perfectly.** The Gate 1 human sign-off for design decisions caught the premature implementation issue before it wasted more code. This was the key workflow improvement discovered during this session.

2. **Pure engine + UI separation.** The game engine (`engine.ts`) has no React dependency — all logic is in a pure reducer. This made the code easy to reason about and review.

3. **Fallback AI pattern.** The try/catch → fallback pattern in the AI client ensures the game never softlocks regardless of network or API issues.

4. **Self-review found real bugs.** The switch-hats review caught P0 issues (hunter non-functional, state mutation outside reducer) that would have been broken at runtime.

## What Could Be Better

1. **Hunter feature was incomplete at initial commit.** The role was defined but had no UI and was partially implemented in the engine. Root cause: rushing through Phase 2 without per-role checklist.

2. **No test framework.** Writing unit tests for the engine would have caught the fallback crashes (empty array `.id` access) before review. Should set up vitest at project start.

3. **AI prompt tight coupling.** The prompt functions and the GameContext are tightly coupled — changing the prompt format requires changing the context dispatch logic. A schema-based contract would decouple them.

## Action Items

- [ ] Set up vitest for engine unit tests
- [ ] Add integration test for full game loop
- [ ] Configure LLM API key and test with real DeepSeek calls
- [ ] Playtest 5 games, collect UX feedback
- [ ] Consider adding schema validation (Zod) for AI responses
