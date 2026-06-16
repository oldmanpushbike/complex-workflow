# ADR: AI Werewolf Game Architecture

Feature ID: 2026-06-13-ai-werewolf
Date: 2026-06-13

## ADR-01: Frontend-Only Game Engine

**Decision:** Game logic runs entirely in the browser via a pure TypeScript state machine (reducer pattern). No backend game server.

**Alternatives considered:**
- Express backend with WebSocket: rejected — overkill for single-player; adds deployment complexity
- Full client-side: chosen — simpler, faster, no server cost beyond LLM proxy

**Consequences:**
- Pro: Zero server state management, instant phase transitions
- Pro: localStorage persistence is sufficient for crash recovery
- Con: No multiplayer path without significant rearchitecture
- Con: Game state is trivially inspectable in browser DevTools (acceptable for single-player)

---

## ADR-02: LLM API Proxy Pattern

**Decision:** AI decisions flow through a Next.js API route (`/api/game/ai-decision`) that proxies requests to the LLM provider. The API key stays server-side in `.env.local`.

**Alternatives considered:**
- Direct browser→LLM calls: rejected — would expose API key
- Backend microservice: rejected — unnecessary for single-player game

**Consequences:**
- Pro: API key secure
- Pro: Can add caching/rate-limiting at proxy layer
- Con: Adds ~100ms latency (local proxy hop)
- Con: Requires Next.js server (won't work in pure static export)

---

## ADR-03: Batch AI Calls (Not Per-Player)

**Decision:** Each phase makes ONE LLM call that returns decisions for all AI players simultaneously.

**Alternatives considered:**
- Per-player streaming: rejected — 7+ sequential calls per phase, 90-225s latency
- Batch with structured output: chosen — ~3 calls per round (night/discussion/votes)

**Consequences:**
- Pro: 4-5x latency reduction (from ~45s to ~10s per phase)
- Pro: Lower token cost
- Con: LLM has omniscient view of all roles; relies on instruction-following to roleplay
- Con: No per-player streaming dialogue (less dramatic feel)

---

## ADR-04: Rule-Based Fallback AI

**Decision:** When LLM is unavailable (API error, timeout, no key configured), the game falls back to a lightweight rule-based AI.

**Alternatives considered:**
- Block game without LLM: rejected — unacceptable UX, game softlocks
- Full fallback: chosen — game always playable, LLM is an enhancement

**Consequences:**
- Pro: Game never softlocks
- Pro: Works immediately without API key configuration
- Con: Fallback dialogue is template-based (lower quality)
