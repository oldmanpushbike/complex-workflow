# Task-Skill Map

Feature ID: 2026-06-13-ai-werewolf
Mapper: Claude (single-agent)
Status: draft
Last updated: 2026-06-13

## Skill Routing

All implementation done by Claude (single-agent mode). No external specialist skills available. Each task self-contained with clear input/output contracts.

## Task Breakdown

---

### T1: Game Engine Core Library

**Skill route:** Claude implements (pure TypeScript, zero dependencies)

**Files to create:**
- `frontend/src/lib/game/types.ts` — All TypeScript types/interfaces
- `frontend/src/lib/game/engine.ts` — Game state machine, rule validation, win checks
- `frontend/src/lib/game/roles.ts` — Role definitions, abilities, constraints
- `frontend/src/lib/game/persistence.ts` — localStorage save/load/clear

**What it does:**
- `createGame(humanName): GameState` — Initialize 7-player game with random roles
- `gameReducer(state, action): GameState` — Pure function, all state transitions
- `validateAction(state, action): boolean` — Rule enforcement layer
- `checkWinCondition(state): 'werewolf' | 'villager' | null`
- `processNightActions(state): GameState` — Resolve all night actions with rule priority
- `processVotes(state): GameState` — Tally votes, handle ties
- `saveGame(state): void` / `loadGame(): GameState | null` / `clearGame(): void`

**Test plan:**
- Unit: role distribution (100 games → always 2W/2V/1S/1Wi/1H)
- Unit: win condition detection (all wolves dead → villager win; wolf count ≥ villager count → werewolf win)
- Unit: Witch can't use both potions same night
- Unit: Dead players can't vote or be targeted
- Unit: Tie-breaking (2 consecutive → forced random)
- Unit: Hunter shoot triggers (night death, vote death)

**Rollback:** Delete `src/lib/game/` directory

**Estimate:** ~300 lines of code, 2-3 hours

---

### T2: AI Service (API Route + Client + Fallback)

**Skill route:** Claude implements (Next.js API route + client service)

**Files to create:**
- `frontend/src/app/api/game/ai-decision/route.ts` — Next.js API route handler
- `frontend/src/lib/ai/provider.ts` — LLM provider abstraction (OpenAI-compatible)
- `frontend/src/lib/ai/prompts.ts` — Prompt templates for each phase (night/discussion/vote)
- `frontend/src/lib/ai/fallback.ts` — Rule-based fallback AI
- `frontend/src/lib/ai/client.ts` — Client-side AI service (calls API route, handles errors)

**What it does:**
- API route receives batched decision request, calls LLM, returns structured response
- Prompt construction: includes game state summary, per-player knowledge, personality
- Response parsing: JSON extraction from LLM output (robust, handles malformed output)
- Fallback: on API error/timeout → rule-based decisions
- LLM provider configurable via env vars (`LLM_API_URL`, `LLM_API_KEY`, `LLM_MODEL`)

**Test plan:**
- Unit: fallback AI produces valid decisions for all action types
- Unit: prompt construction includes all required context fields
- Integration: API route returns valid decision structure
- Manual: real LLM call produces sensible Chinese dialogue

**Rollback:** Delete `src/lib/ai/` and `src/app/api/game/`

**Estimate:** ~400 lines, 3-4 hours

---

### T3: React Game State Context

**Skill route:** Claude implements (React Context + useReducer)

**Files to create:**
- `frontend/src/lib/game/GameContext.tsx` — React context provider + reducer hook
- `frontend/src/lib/game/useGame.ts` — Custom hook for consuming game state

**What it does:**
- Wraps `gameReducer` in React `useReducer`
- Provides `gameState`, `dispatch`, `isProcessing`, `processingMessage`
- Orchestrates async AI calls during night/day phases
- Handles localStorage persistence on phase changes
- Exposes action creators: `startGame()`, `selectNightTarget()`, `sendMessage()`, `castVote()`, `confirmAction()`

**Test plan:**
- Integration: full game loop in React testing environment
- Unit: localStorage save/load cycle preserves all state

**Rollback:** Delete context files

**Estimate:** ~200 lines, 2 hours

---

### T4: Setup & Role Reveal Screens

**Skill route:** Claude implements (React components + Tailwind CSS)

**Files to create:**
- `frontend/src/components/werewolf/SetupScreen.tsx`
- `frontend/src/components/werewolf/RoleRevealScreen.tsx`
- `frontend/src/components/werewolf/RoleCard.tsx`

**What it does:**
- SetupScreen: Game title "AI 狼人杀" with glow effect, name input with validation, "开始游戏" button with hover animation
- RoleRevealScreen: Card flip animation (CSS transform), role icon/name/ability description, "继续" button
- Dark fantasy aesthetic: deep navy bg, gold accents, card texture

**Test plan:**
- Visual: verify all 5 roles have correct icon/description
- Manual: name validation blocks empty/special-char input

**Rollback:** Delete component files, remove route

**Estimate:** ~250 lines, 2-3 hours

---

### T5: Game Board Shell & Player Grid

**Skill route:** Claude implements

**Files to create:**
- `frontend/src/components/werewolf/GameBoard.tsx` — Main game layout
- `frontend/src/components/werewolf/PlayerGrid.tsx` — Player cards in semi-circle
- `frontend/src/components/werewolf/PlayerCard.tsx` — Individual player card
- `frontend/src/components/werewolf/PhaseIndicator.tsx` — "第N夜" / "第N天"

**What it does:**
- GameBoard: 3-column layout (players left, action center, log right)
- PlayerGrid: 7 player cards arranged in arc/semi-circle, dead players grayed out with 💀
- PlayerCard: avatar (emoji), name, alive/dead status, vote marker, role icon (if revealed)
- PhaseIndicator: animated moon/sun icon, round counter

**Test plan:**
- Visual: all 7 players visible, layout works at 1280px+
- Unit: player card shows correct state for alive/dead/unknown role

**Rollback:** Delete component files

**Estimate:** ~300 lines, 2-3 hours

---

### T6: Night Phase & Action Panel

**Skill route:** Claude implements

**Files to create:**
- `frontend/src/components/werewolf/NightPhase.tsx` — Night phase orchestrator
- `frontend/src/components/werewolf/ActionPanel.tsx` — Context-sensitive action UI
- `frontend/src/components/werewolf/NightAnimation.tsx` — Moon/stars animation

**What it does:**
- Night processing: "夜晚行动中..." with animated moon, AI "thinking" indicators
- Human Werewolf: select kill target from living non-wolves
- Human Seer: select check target → reveal result with card peek animation
- Human Witch: see tonight's victim → choose Save (antidote) / Poison (select target) / Pass
- Human Villager: "等待天亮..." (no night action)

**Test plan:**
- Unit: target selection filters dead players
- Unit: Witch can't select both save AND poison
- Manual: all 5 role experiences have correct night UI

**Rollback:** Delete component files

**Estimate:** ~350 lines, 3-4 hours

---

### T7: Day Phase — Discussion & Chat

**Skill route:** Claude implements

**Files to create:**
- `frontend/src/components/werewolf/DayPhase.tsx` — Day phase orchestrator
- `frontend/src/components/werewolf/ChatBox.tsx` — Scrollable chat container
- `frontend/src/components/werewolf/ChatMessage.tsx` — Single message bubble
- `frontend/src/components/werewolf/ChatInput.tsx` — Human input + send button

**What it does:**
- Death announcement: dramatic reveal of who died (or "平安夜" if no deaths)
- ChatBox: messages appear with typing indicator, auto-scroll
- ChatMessage: avatar + name + speech bubble (colored by werewolf/villager alignment after game reveals)
- ChatInput: text input, Enter to send, sanitization
- AI messages flow in after batch generation with staggered display

**Test plan:**
- Unit: message sanitization strips HTML
- Manual: typing indicator visible, auto-scroll works

**Rollback:** Delete component files

**Estimate:** ~250 lines, 2-3 hours

---

### T8: Vote Phase

**Skill route:** Claude implements

**Files to create:**
- `frontend/src/components/werewolf/VotePanel.tsx` — Vote selection & results
- `frontend/src/components/werewolf/VoteResult.tsx` — Vote tally animation

**What it does:**
- Show "投票阶段" indicator
- Clickable player cards to select vote target
- AI votes processed with short "thinking" delay
- Vote reveal: count-up animation per player, highlight eliminated player
- Tie handling: "平票，无人被放逐" message; 2nd tie triggers forced random
- Elimination animation if someone is voted out

**Test plan:**
- Unit: human vote registered correctly
- Unit: tie detection and forced random after 2nd tie
- Manual: vote result animation plays smoothly

**Rollback:** Delete component files

**Estimate:** ~200 lines, 2 hours

---

### T9: Game Over Screen

**Skill route:** Claude implements

**Files to create:**
- `frontend/src/components/werewolf/GameOverScreen.tsx`

**What it does:**
- Victory/defeat banner: "村民阵营胜利!" (green) or "狼人阵营胜利!" (red)
- Role reveal: flip all player cards to show true roles
- Game stats summary: rounds played, key events timeline
- "再来一局" button → reset state, return to setup

**Test plan:**
- Unit: correct winner displayed based on game state
- Manual: all roles correctly revealed

**Rollback:** Delete component file

**Estimate:** ~200 lines, 2 hours

---

### T10: Page Route & Layout Integration

**Skill route:** Claude implements

**Files to create/modify:**
- `frontend/src/app/werewolf/page.tsx` — Game page (client component)
- `frontend/src/app/werewolf/layout.tsx` — Optional layout with metadata
- `frontend/src/app/globals.css` — Add werewolf-specific CSS variables/animations

**What it does:**
- Wire all components together with GameContext provider
- Page metadata (title: "AI 狼人杀")
- Global CSS: dark theme variables, card flip animation keyframes, glow effects

**Test plan:**
- E2E: page loads without errors
- Manual: dark theme applied consistently

**Rollback:** Delete `/werewolf` route directory

**Estimate:** ~100 lines, 1 hour

---

### T11: Polish & Animations

**Skill route:** Claude implements

**What it does:**
- Card flip animation (CSS 3D transform)
- Phase transition fade (opacity + scale)
- AI message stagger (messages appear with 800ms delay each)
- Vote reveal bounce animation
- Death: player card fade to grayscale + 💀 overlay
- Role reveal: sparkle/glow effect
- Loading states for AI processing

**Test plan:**
- Manual: all animations smooth at 60fps
- Manual: no layout shift during animations

**Rollback:** Remove animation classes

**Estimate:** ~200 lines, 2 hours

---

## Task Dependency Graph

```
T1 (Engine) ──┬── T3 (Context) ──┬── T4 (Setup/Reveal)
              │                  ├── T5 (Board/Players)
              ├── T2 (AI) ───────├── T6 (Night Phase)
                                  ├── T7 (Day/Chat)
                                  ├── T8 (Vote)
                                  ├── T9 (Game Over)
                                  └── T10 (Page Route) ── T11 (Polish)
```

- T1 and T2 can be done in parallel (no dependency between them)
- T3 depends on T1
- T4-T9 depend on T3 (need context)
- T10 depends on T4-T9 (need all components)
- T11 is last (polish pass)

## Effort Summary

| Task | Est. Hours | Priority |
|---|---|---|
| T1: Game Engine | 2-3h | P0 — Foundation |
| T2: AI Service | 3-4h | P0 — Foundation |
| T3: Context | 2h | P0 — Foundation |
| T4: Setup/Reveal | 2-3h | P1 — User-visible |
| T5: Board/Players | 2-3h | P1 — User-visible |
| T6: Night Phase | 3-4h | P1 — Core gameplay |
| T7: Day/Chat | 2-3h | P1 — Core gameplay |
| T8: Vote | 2h | P1 — Core gameplay |
| T9: Game Over | 2h | P1 — User-visible |
| T10: Page Route | 1h | P2 — Integration |
| T11: Polish | 2h | P2 — Quality |
| **Total** | **23-29h** | |

## Implementation Order

Phase 1 (Foundation): T1 → T2 → T3
Phase 2 (Core Screens): T4 → T5 → T6 → T7 → T8 → T9
Phase 3 (Integration): T10 → T11

Each phase ends with a working increment. Phase 1 = engine + AI work in isolation. Phase 2 = full gameplay loop. Phase 3 = integrated page + polish.
