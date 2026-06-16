# OpenSpec Proposal

Feature ID: 2026-06-13-ai-werewolf
Owner: Claude (orchestrator, single-agent mode)
Status: amended (post-grill-me, 2026-06-13)
Last updated: 2026-06-13

## Problem

Users want to play 狼人杀 (Werewolf/Mafia) but cannot always gather 6-12 people for a real game. An AI-powered web version lets a single human play against intelligent AI opponents anytime, with a polished game flow and beautiful UI that captures the tension and fun of the social deduction genre.

## Goals

- Build a complete single-player Werewolf game with 6 AI opponents (7-player standard setup)
- Beautiful, modern dark-theme UI with card aesthetics, animations, and atmospheric design
- Clear, guided game flow: role assignment → night phase → day phase → vote → repeat → game over
- AI players powered by LLM with distinct personalities, strategic reasoning, and natural-language discussion
- Game engine runs entirely in the browser (frontend-only, no backend dependency for game logic)
- Chinese language UI and AI dialogue (target audience is Chinese-speaking)
- Role set: Werewolf ×2, Villager ×2, Seer, Witch, Hunter

## Non-Goals

- Multiplayer / online play (single-player only)
- Voice chat or real-time audio
- Mobile native app (web-first, responsive is a plus)
- User accounts, leaderboards, or persistence (play-and-done)
- Custom role configurations in v1
- Backend server (all game logic + AI runs client-side via API calls)

## Users And Actors

- **Primary user:** A single human player who wants to play Werewolf against AI
- **AI Werewolves:** LLM-powered, coordinate to kill villagers, deceive during day discussion
- **AI Villagers:** LLM-powered, try to identify werewolves through discussion and voting
- **AI Seer:** LLM-powered, checks identities at night, shares findings strategically
- **AI Witch:** LLM-powered, decides when to use antidote/poison
- **AI Hunter:** LLM-powered, chooses shot target when dying
- **Game Master (system):** Coordinates phases, enforces rules, announces events

## Current Behavior

The project currently contains a personal blog system (Next.js 16 + Express backend + Prisma/SQLite). No game-related code exists. We will build the werewolf game as a new section under the frontend, reusing the existing Next.js + React 19 + Tailwind CSS 4 + TypeScript stack.

Existing assets:
- `frontend/` — Next.js 16.2.9, React 19.2.4, Tailwind CSS 4, TypeScript
- `backend/` — Express + Prisma (may not be needed for game; game logic is frontend-only)

## Desired Behavior

### Core Game Loop

```
Setup → Role Deal → [Night → Day] × N → Game Over
```

1. **Setup:** Player enters name, clicks "Start Game". System assigns roles randomly.
2. **Role Reveal:** Player sees their role card with animation. Brief description of abilities.
3. **Night Phase:**
   - Werewolves wake → AI picks a victim (LLM reasons about who to kill)
   - Seer wakes → AI picks a player to check (LLM reasons about who is suspicious)
   - Witch wakes → AI decides to use antidote (save) or poison (kill) or pass
   - System records all night actions
4. **Day Phase:**
   - System announces night results (who died, if any)
   - If Hunter was killed, Hunter chooses shot target
   - Discussion round: all living AI players speak in character (LLM generates dialogue)
   - Human player can also "speak" (type message, displayed in chat)
   - Vote round: all players vote to eliminate someone
   - Tie = no elimination (or random among tied)
   - System announces elimination result
5. **Game Over Check:**
   - All werewolves eliminated → Villager team wins
   - Werewolves ≥ remaining villagers → Werewolf team wins
6. **Victory Screen:** Show winning team, reveal all roles, play summary

### AI Behavior Requirements

- Each AI player has a consistent personality (name + trait)
- AI decisions are context-aware (knows game state, previous events, who is alive/dead)
- AI dialogue sounds natural, with rhetorical strategies (accusation, defense, analysis)
- AI werewolves coordinate covertly (but imperfectly — they can make mistakes)
- AI villagers reason with limited information
- AI Seer shares check results strategically (may hide early to avoid being targeted)
- AI Witch balances saving vs. poisoning strategically

## User Flows

### Flow 1: Complete Game (Happy Path)

Given: Player visits the game page
When: Player enters name and clicks "开始游戏"
Then:
- Loading screen with card shuffle animation
- Role card revealed with flip animation
- Night 1 begins: system processes AI night actions (3-5 seconds with thinking indicators)
- Day 1 begins: death announcement, AI discussion (messages appear one by one)
- Player types a message, it appears in chat
- Vote phase: all players vote, results shown with animation
- Cycle continues until game over condition met
- Victory/defeat screen with role reveal and game stats

### Flow 2: Player Dies Early

Given: Player is killed during night or eliminated by vote
When: Player dies
Then:
- Death animation plays
- Player enters "spectator mode" — can watch remaining game unfold
- AI continues playing automatically
- Final result shown at game end

### Flow 3: Special Abilities

Given: Player has a special role (Seer/Witch/Hunter)
When: Their ability phase arrives
Then:
- UI highlights available actions clearly
- Seer: Select a player to investigate → see "Werewolf" or "Not Werewolf"
- Witch: See who died tonight → Choose: Save / Poison (select target) / Pass
- Hunter: When dying → Choose who to shoot

### Flow 4: Game Restart

Given: Game has ended
When: Player clicks "再来一局"
Then: Full reset, new role assignment, new AI personalities

## Data Model

### Game State

```typescript
interface GameState {
  phase: 'setup' | 'role-reveal' | 'night' | 'day-discussion' | 'day-vote' | 'game-over';
  round: number;                    // Current round number (1-based)
  players: Player[];
  nightActions: NightAction[];      // Current night's actions
  dayDiscussion: ChatMessage[];     // Current day's discussion
  votes: Record<string, string>;    // voterId -> targetId
  gameLog: GameEvent[];             // Complete history
  winner: 'werewolf' | 'villager' | null;
}

interface Player {
  id: string;
  name: string;
  role: 'werewolf' | 'villager' | 'seer' | 'witch' | 'hunter';
  isHuman: boolean;
  isAlive: boolean;
  personality?: string;             // AI personality trait
  avatar: string;                   // Emoji/icon for the player
}

interface NightAction {
  type: 'wolf-kill' | 'seer-check' | 'witch-save' | 'witch-poison';
  actorId: string;
  targetId: string;
  result?: string;
}

interface ChatMessage {
  playerId: string;
  content: string;
  timestamp: number;
}

interface GameEvent {
  round: number;
  phase: string;
  type: string;
  description: string;              // Human-readable Chinese text
  timestamp: number;
}
```

### State Transitions

```
setup → role-reveal → night → day-discussion → day-vote → [night | game-over]
                                                                    ↑
                                                          (loop back)
```

## UI Design

### Visual Theme
- **Dark fantasy aesthetic:** Deep navy/purple background, gold accents, card textures
- **Color palette:**
  - Background: `#0a0a1a` (deep night blue)
  - Card bg: `#1a1a2e` with subtle border glow
  - Gold accent: `#d4a574` for highlights, buttons, role names
  - Werewolf red: `#8b0000`
  - Villager green: `#2d5a27`
  - Special role purple: `#4a2d8a`
- **Typography:** Chinese-friendly serif for titles, sans-serif for body
- **Animations:** Card flips, fade transitions between phases, text typing effect for AI dialogue, vote reveal bounce

### Component Tree

```
<GamePage>
├── <SetupScreen>                    // Name input + Start button
│   ├── <GameTitle />                // "AI 狼人杀" with glow effect
│   ├── <NameInput />
│   ├── <PlayerCountSelector />      // Fixed at 7 for v1
│   └── <StartButton />
│
├── <RoleRevealScreen>               // Animated card flip
│   ├── <CardFlipAnimation />
│   ├── <RoleCard>                   // Shows role name, icon, ability desc
│   │   ├── <RoleIcon />             // 🐺 🧙 etc
│   │   ├── <RoleName />
│   │   └── <AbilityDescription />
│   └── <ContinueButton />
│
├── <GameBoard>                      // Main game view
│   ├── <PhaseIndicator />           // "第2夜" / "第2天" with icon
│   ├── <PlayerGrid>                 // 7 player cards arranged in circle/semi-circle
│   │   └── <PlayerCard />[]
│   │       ├── <Avatar />
│   │       ├── <PlayerName />
│   │       ├── <StatusBadge />      // Alive/Dead 💀
│   │       └── <VoteMarker />       // Shows vote target during voting
│   │
│   ├── <ActionPanel>                // Context-sensitive area
│   │   ├── [Night: "夜晚行动中..." with moon animation]
│   │   ├── [Discussion: Chat window]
│   │   ├── [Vote: Select target prompt]
│   │   └── [Special ability UI for Seer/Witch/Hunter]
│   │
│   ├── <ChatBox>                    // Day discussion messages
│   │   ├── <ChatMessage />[]
│   │   │   ├── <Avatar />
│   │   │   ├── <Bubble>             // Speech bubble with player color
│   │   │   └── <Timestamp />
│   │   └── <ChatInput />            // Human player's message input
│   │
│   ├── <VotePanel>                  // Vote selection UI
│   │   ├── <PlayerSelectGrid />     // Clickable player cards
│   │   ├── <VoteConfirmButton />
│   │   └── <VoteResults />          // Show who voted for whom
│   │
│   └── <GameLog>                    // Collapsible sidebar: event history
│       └── <GameEvent />[]
│
└── <GameOverScreen>
    ├── <VictoryBanner />            // "村民胜利!" or "狼人胜利!"
    ├── <RoleRevealAll />            // Flip all player cards
    ├── <GameStats />                // Rounds played, key events
    └── <PlayAgainButton />
```

## API / Interface Contract

### AI Service Interface

The game will call an LLM API for AI player decisions and dialogue. We use a clean abstraction so the LLM provider can be swapped.

```typescript
// AI decision request
interface AIDecisionRequest {
  gameState: {
    round: number;
    phase: string;
    players: Array<{id, name, isAlive, role?}>;  // role only if known to this player
    events: GameEvent[];
  };
  player: {
    id: string;
    name: string;
    role: string;
    personality: string;
    knownInfo: string[];   // What this player knows (seer checks, etc.)
  };
  action: 'discuss' | 'vote' | 'wolf-kill' | 'seer-check' | 'witch-decide' | 'hunter-shoot';
  options: string[];       // Valid targets/choices
}
```

### LLM Provider (OpenAI-compatible)

```
POST /api/game/ai-decision
Body: AIDecisionRequest
Response: { decision: string, reasoning: string }
```

For v1, AI calls go directly from the frontend to a Next.js API route that proxies to the LLM. This keeps the API key server-side.

### UI State Management (React Context)

```typescript
interface GameContext {
  gameState: GameState;
  dispatch: (action: GameAction) => void;
  isProcessing: boolean;      // True when AI is "thinking"
  processingMessage: string;  // "狼人在选择目标..." etc.
}
```

## Permissions And Security

- No authentication needed (single-player game)
- LLM API key stored in `.env.local` (server-side only)
- API route `/api/game/ai-decision` proxies LLM calls to protect key
- Rate limiting on AI endpoint to prevent abuse (optional for v1)
- Input sanitization on player name and chat messages

## Migration / Rollback

- Migration needed: No — this is a new feature, no existing data to migrate
- Rollback path: Remove `/werewolf` route and `/api/game/*` routes
- Data safety note: No user data persisted; game state is ephemeral

This feature does not modify existing blog functionality. It is additive only.

## Acceptance Criteria

- [ ] AC1: Player can enter name, start game, and receive a random role with animated reveal
- [ ] AC2: Night phase executes: wolves kill, seer checks, witch decides — all AI-driven
- [ ] AC3: Day phase: death announced, AI players discuss in natural Chinese, human can type messages
- [ ] AC4: Vote phase: player selects target, all votes tallied, result revealed with animation
- [ ] AC5: Game correctly detects win conditions (all wolves dead OR wolves ≥ villagers)
- [ ] AC6: Game over screen shows winner, reveals all roles, allows restart
- [ ] AC7: Special abilities work correctly for human player (Seer check, Witch save/poison, Hunter shot)
- [ ] AC8: AI produces contextually appropriate dialogue (not random/generic)
- [ ] AC9: Player death is handled gracefully (spectator mode)
- [ ] AC10: UI is visually polished: dark theme, card animations, smooth phase transitions
- [ ] AC11: Game works entirely through the browser (no persistent server state needed)
- [ ] AC12: All text is in Chinese
- [ ] AC13: LLM API failure triggers fallback AI (rule-based); game continues without softlock
- [ ] AC14: Page refresh mid-game: game state restored from localStorage, player offered "Resume"
- [ ] AC15: Game forcibly resolves after 15 rounds (forced random elimination each day)
- [ ] AC16: All AI decisions validated by game engine before applying (Witch can't double-use potions, etc.)
- [ ] AC17: AI calls are batched: night actions in one call, day discussion in one call, votes in one call

## Verification Plan

- Unit tests: Game engine logic (role assignment, win condition check, vote tally)
- Integration tests: AI decision flow, phase transitions
- E2E/manual checks: Play through 5 complete games, verify no softlocks
- Static checks: TypeScript strict mode, linting

## Open Questions

- Q1: Which LLM provider to use? (DeepSeek, OpenAI, Anthropic?) — affects API route implementation and cost
- Q2: Should AI dialogue be generated one message at a time (streaming) or all at once? Streaming is more realistic but complex
- Q3: Should the game support the player choosing their preferred role, or always random?
- Q4: How many rounds maximum before the game forcibly ends? (prevent infinite loops if AI is passive)
- Q5: Should there be sound effects / background music? (atmospheric but adds complexity)

## Decision Log

| Date | Decision | Reason | Owner |
|---|---|---|---|
| 2026-06-13 | Single-agent mode (Codex unavailable) | Codex MCP/CLI not reachable; Claude orchestrates with self-review | Claude |
| 2026-06-13 | Frontend-only game logic + Next.js API route for LLM proxy | No need for persistent backend; game state lives in React context; API key stays server-side | Claude |
| 2026-06-13 | 7-player standard setup (2 wolves, 2 villagers, 1 seer, 1 witch, 1 hunter) | Most balanced and popular configuration; good for v1 | Claude |
| 2026-06-13 | Use existing Next.js 16 + React 19 + Tailwind CSS 4 stack | Reuse what's already in the project; consistent technology | Claude |
| 2026-06-13 | Chinese-only UI and AI dialogue | Target user is Chinese-speaking; keeping it single-language simplifies design | Claude |
| 2026-06-13 | Add fallback rule-based AI | P0 grill-me finding G2: LLM API failure must not softlock the game | Claude |
| 2026-06-13 | Add localStorage game state persistence | P1 grill-me finding G3: page refresh loses all state | Claude |
| 2026-06-13 | Add AI batching: night/discussion/votes each in one LLM call | P1 grill-me finding G4: 15 calls/round is too slow/expensive | Claude |
| 2026-06-13 | Max 15 rounds, then forced random elimination on ties | P1 grill-me finding G6: prevent infinite game loops | Claude |
| 2026-06-13 | Game engine validation layer for all AI decisions | P1 grill-me finding G8: enforce rules regardless of LLM output | Claude |
| 2026-06-13 | Q1 resolved: Use OpenAI-compatible API (DeepSeek as primary, configurable) | Lowest cost for Chinese language; easy to swap provider | Claude |
| 2026-06-13 | Q2 resolved: One batched call per phase, not per-player streaming | Batch reduces latency from 90s+ to ~30s per round; complexity budget | Claude |
| 2026-06-13 | Q3 resolved: Always random role assignment | Fair play; avoids "always pick werewolf" burnout | Claude |
| 2026-06-13 | Q4 resolved: 15 round max with forced elimination | Prevents infinite games; 15 rounds covers vast majority of normal games | Claude |
| 2026-06-13 | Q5 resolved: No sound in v1; visual atmosphere only | Complexity budget; can add ambient music/sfx in v2 | Claude |

## Post-grill-me Amendments (2026-06-13)

### A1: Fallback AI System
When LLM API returns an error or times out (>10s), the game engine falls back to a simple rule-based AI:
- Werewolf kill: target a random villager-side player (prefer Seer if known)
- Seer check: check a random unchecked living player
- Witch: 70% save first death, 30% save self, poison on round 3+ randomly
- Discussion: use template messages based on role + game situation
- Vote: random weighted by suspicion heuristics

### A2: localStorage State Persistence
After every phase transition (`state.phase` change), serialize `GameState` to `localStorage` under key `werewolf-game-state`. On game page load, check for saved state. If found, show "Resume Game" option. Clear on game over or explicit "New Game."

### A3: AI Call Batching
Replace per-player LLM calls with phase-level batch calls:
- **Night batch:** `{ phase: 'night', wolves: [{id, name, personality}], seer: {id, name}, witch: {id, name}, livingPlayers: [...], events: [...] }` → returns `{ wolfTarget, seerCheck, witchAction }`
- **Discussion batch:** `{ phase: 'discussion', players: [{id, name, role, personality, knownInfo}], events: [...] }` → returns `{ messages: [{playerId, content}] }`
- **Vote batch:** `{ phase: 'vote', players: [...], discussion: [...], events: [...] }` → returns `{ votes: [{playerId, targetId}] }`

### A4: Game Engine Validation Layer
```typescript
function validateNightAction(action, gameState): boolean
function validateVote(voterId, targetId, gameState): boolean
function checkWinCondition(gameState): 'werewolf' | 'villager' | null
```
Invalid AI decisions → retry once with error prompt → fallback to random valid choice.

### A5: Input Sanitization
- Player name: max 20 chars, regex `/^[\w一-鿿]{1,20}$/`
- Chat messages: strip HTML tags, max 500 chars, reject strings containing common prompt-injection patterns

### A6: Hunter Timing Specification
Event ordering when Hunter is killed:
1. If killed at night → Hunter shoots immediately (before day announcement)
2. If eliminated by vote → Hunter shoots after vote result, before death resolves
3. If killed by Witch poison AND wolf kill in same night → only one death event, Hunter shoots once

