# grill-me Report

Feature ID: 2026-06-13-ai-werewolf
Reviewer: Claude (single-agent manual-grill)
Source: manual-grill
Status: answered — all P0/P1 findings addressed in spec amendments A1-A6

## Summary

The proposal is well-scoped for v1, but there are critical risks around **AI consistency** (LLMs forgetting their own past knowledge), **API failure resilience** (no fallback when LLM errors), **state durability** (page refresh = game lost), and **cost/latency** (7+ LLM calls per round). These must be addressed before implementation, or explicitly accepted as residual risk with mitigations.

---

## Challenge Questions

### Product Fit

- **Q: Is the spectator mode actually engaging?** When the human player dies, they become a passive observer. If the game has 4+ rounds remaining, this could be a 2-3 minute wait with nothing to do. Consider: "Skip to result" button, or speed-up toggle.
- **Q: What about the werewolf team experience?** Human players assigned werewolf role need to participate in wolf-kill decision AND pretend to be villager during day. This dual-identity UX needs careful design.

### Edge Cases

- **E1: AI Witch uses both antidote and poison in the same night.** Game rules: Witch can use only ONE potion per night. The game engine must enforce this even if LLM asks for both. **Severity: P1**
- **E2: AI Seer checks a dead player.** Should not be allowed. Player list must exclude dead. **Severity: P2** (easy to filter in code)
- **E3: All players vote for different targets → 7-way tie.** Proposal says "no elimination." But repeated ties could make the game endless. Need max 2 ties → forced random elimination. **Severity: P1**
- **E4: Human player refreshes the page mid-game.** All state is in React context → game lost. User frustrated. **Severity: P1**
- **E5: Hunter is killed by poison AND vote in the same round.** Does Hunter shoot once or twice? Rule: Hunter ability triggers once per death event. Poison at night + vote elimination are separate deaths → but Hunter can only die once. If killed at night by poison, Hunter shoots, then daytime vote obviously cannot kill a dead player. Need to think through the ordering carefully. **Severity: P1**
- **E6: Only 2 players left (1 wolf, 1 villager).** Game should end immediately — werewolf win (wolf ≥ villager). Check this after every death, not just at end of round. **Severity: P1**

### Security And Privacy

- **S1: LLM API key exposure.** The API route `/api/game/ai-decision` must NOT expose the key to the client. Key stays in `process.env` on server. **Severity: P0**
- **S2: Prompt injection via player name or chat message.** A player named "Ignore all previous instructions..." or typing malicious chat could pollute the LLM prompt. Must sanitize and isolate user input from system prompt. **Severity: P1**
- **S3: API route abuse.** An unauthenticated `/api/game/ai-decision` endpoint could be called directly by anyone, burning LLM credits. Need at minimum an origin check or simple rate limit. **Severity: P1**
- **S4: LLM training on game data.** The player's chat messages and game decisions are sent to the LLM provider. This is inherent to the feature but should be noted (no PII beyond player-chosen display name). **Severity: P3** (transparency note)

### Data And Migration

- No migration concerns (new feature). 
- **But:** State durability is a concern. If we don't persist game state, any interruption kills the game. localStorage backup every state transition would be cheap insurance. **Severity: P2**

### Performance And Scale

- **Perf1: LLM call volume.** Each night phase: 1 wolf-kill decision + 1 seer check + 1 witch decision = 3 LLM calls. Each day phase: 6 discussion messages + 6 vote decisions = 12 LLM calls. Total per round: ~15 LLM calls. At 2-5 seconds per call, a 3-round game takes 90-225 seconds just in AI processing. **Severity: P1**
- **Perf2: Mitigation strategies —** Batch wolf-kill into one call (all wolves agree). Batch discussion: generate all AI messages in one call with a structured output. This cuts calls from ~15/round to ~4/round. **Must implement batching.**
- **Perf3: Context window growth.** Sending the full game log to the LLM each call means prompts grow linearly. A 10-round game with full chat history could exceed token limits. Need to truncate/summarize older events. **Severity: P1**

### Testing

- What test fails if the win condition is broken? → E2E: After all wolves eliminated, game must show villager victory.
- What test fails if role assignment is unfair? → Unit test: with 7 players, verify exactly 2 wolves, 2 villagers, 1 seer, 1 witch, 1 hunter.
- What manual check is still needed? → AI dialogue quality cannot be automatically tested. Requires human playtest.

---

## Findings

| ID | Severity | Finding | Required response | Resolution |---|---|---|
| G1 | P0 | LLM API key must never reach client; API route is the only call path | Confirm API route design; key in .env.local only | ✅ Spec §A5, existing API route design |
| G2 | P1 | No LLM failure fallback — if API errors, game softlocks | Add fallback: rule-based AI decisions when LLM unavailable | ✅ Spec §A1 |
| G3 | P1 | Page refresh = game state lost (React context only) | Add localStorage persistence on every state transition | ✅ Spec §A2 |
| G4 | P1 | ~15 LLM calls per round = 90-225s per game, high cost | Batch AI calls: one call for all-night actions, one for all discussion, one for all votes | ✅ Spec §A3 |
| G5 | P1 | AI knowledge inconsistency: Seer might forget past check results, Witch might forget potion status | Include per-player knowledge state in prompt; add a "notebook" system | ✅ Spec §A3 (per-player knownInfo in batch prompt) |
| G6 | P1 | Repeated vote ties → infinite game | Max 2 consecutive ties → random elimination among tied players | ✅ Spec §A4, AC15 |
| G7 | P1 | Prompt injection via player name/chat | Sanitize inputs; use structured separation between system prompt and user content | ✅ Spec §A5 |
| G8 | P1 | Witch dual-potion constraint must be enforced by engine, not trusted to LLM | Game engine validates all AI decisions against game rules | ✅ Spec §A4 |
| G9 | P2 | Spectator mode boring if game goes long | Add "Skip to Result" button for dead human player | ✅ Accepted; will implement skip button |
| G10 | P2 | Hunter death trigger ordering ambiguity | Document exact ordering: night-kill → Hunter shoots immediately if killed; day-vote → Hunter shoots before elimination resolution | ✅ Spec §A6 |
| G11 | P3 | No sound effects / atmosphere | Accept for v1; can add later | ✅ Accepted risk |

## Spec Amendments Needed

1. **Add fallback AI:** When LLM API fails, use a simple rule-based decision system (random weighted by game theory). This is non-negotiable for robustness.
2. **Add localStorage checkpointing:** Save game state to localStorage after each phase transition. On page load, check for saved state and offer "Resume" option.
3. **Add max-round limit:** 15 rounds max. At round 15, forced random elimination each day until resolution.
4. **Add AI batching design:** Specify that night actions are resolved in one batch call, day discussion in one batch call, votes in one batch call. This changes the AIDecisionRequest schema.
5. **Add input sanitization spec:** Player names limited to 20 chars, alphanumeric + Chinese. Chat messages sanitized, no special tokens.
6. **Add game engine validation layer:** All AI decisions pass through a validation function before being applied to game state. Invalid decisions → retry with clarification prompt (max 1 retry) → fallback to random valid choice.
7. **Clarify Hunter timing:** Add explicit event ordering to the data model.

## Accepted Residual Risks

| Risk | Why accepted | Owner | Review date |
|---|---|---|---|
| AI dialogue quality varies by LLM model | Subjective; v1 goal is "good enough to be fun," not Turing-test quality | Claude | 2026-06-13 |
| Game context sent to LLM provider | Inherent to AI feature; display name is the only user-generated PII | Claude | 2026-06-13 |
| No mobile-specific layout | v1 is desktop-first; responsive is a nice-to-have | Claude | 2026-06-13 |
| Single-player only, no online multiplayer | Explicitly out of scope for v1 | Claude | 2026-06-13 |
