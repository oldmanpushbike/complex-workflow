#!/usr/bin/env python3
"""
workflow/eval/score.py -- Deterministic Scoring Engine

Scores a feature's workflow health using only arithmetic and filesystem checks.
Zero LLM calls, zero network requests. 3 runs produce identical hashes.

Usage:
    python score.py --feature <feature-id> [--baseline <baselines.json>] [--output <score.json>]
    python score.py --all [--baseline <baselines.json>] [--output-dir <dir>]

Constraints:
    - Python 3.8+
    - Stdlib only: json, os, sys, hashlib, datetime, pathlib, glob
    - No LLM SDK imports, no network requests
"""

import json
import os
import sys
import hashlib
import argparse
from datetime import datetime, timezone
from pathlib import Path
from glob import glob as glob_fn


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

WEIGHTS = {
    "processIntegrity": 0.22,
    "reviewQuality": 0.22,
    "degradationFrequency": 0.15,
    "humanResponseLatency": 0.10,
    "experienceCaptureRate": 0.12,
    "retrySuccessRate": 0.10,
    "documentHealth": 0.09,
}

DIMENSION_ORDER = [
    "processIntegrity",
    "reviewQuality",
    "degradationFrequency",
    "humanResponseLatency",
    "experienceCaptureRate",
    "retrySuccessRate",
    "documentHealth",
]

# Gate -> minimum S-state number (extracted from S1, S2, ... S9)
# Gate 1 → S1, Gate 2 → S2, Gate 3 → S3, Gate 4 → S4,
# Gate 5 → S6, Gate 6 → S7, Gate 7 → S8
GATE_STATE_THRESHOLD = {
    "gate-1": 1,
    "gate-2": 2,
    "gate-3": 3,
    "gate-4": 4,
    "gate-5": 6,
    "gate-6": 7,
    "gate-7": 8,
}

# Minimum artifact file sizes in bytes (matching gate-check.sh)
ARTIFACT_MIN_SIZE = {
    "01-openspec-proposal.md": 500,
    "02-grill-me-report.md": 300,
    "03-task-skill-map.md": 300,
    "04-implementation-plan.md": 100,
    "05-verification-log.md": 100,
    "06-adr.md": 100,
    "07-task-retro.md": 100,
}

# D3: severity weight matrix per eventType
FALLBACK_SEVERITY_WEIGHT = {
    "orchestrator_unreachable": 5,
    "human_unavailable": 5,
    "agent_disagreement": 4,
    "multiple_tool_failures": 4,
    "challenger_unreachable": 3,
    "reviewer_unreachable": 3,
    "grill_unavailable": 2,
    "tests_unavailable": 2,
    "superpowers_unavailable": 2,
    "partial_grill": 1,
    "partial_review": 1,
    "openspec_unavailable": 1,
    "find_skill_unavailable": 1,
    "mcp_unavailable": 1,
    "network_unavailable": 1,
}

VALID_GATE_STATUSES = {"pending", "passed", "failed", "skipped"}
VALID_STATES = {"S0", "S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9"}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_state_num(state_str):
    """Extract integer from S-state string. Returns -1 if invalid."""
    if state_str and isinstance(state_str, str) and state_str.startswith("S"):
        try:
            return int(state_str[1:])
        except ValueError:
            return -1
    return -1


def _iso_to_dt(iso_str):
    """Parse an ISO 8601 string to a datetime. Returns None on failure."""
    if not iso_str:
        return None
    try:
        # Handle Z suffix
        s = iso_str.replace("Z", "+00:00")
        return datetime.fromisoformat(s)
    except (ValueError, TypeError):
        return None


def _hours_between(dt_a, dt_b):
    """Return absolute hours between two datetimes, or None."""
    if dt_a is None or dt_b is None:
        return None
    return abs((dt_a - dt_b).total_seconds()) / 3600.0


def _read_file(path):
    """Read file contents as string. Returns None on failure."""
    try:
        return Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def _file_size(path):
    """Return file size in bytes, or 0 if missing/unreadable."""
    try:
        return Path(path).stat().st_size
    except OSError:
        return 0


# ---------------------------------------------------------------------------
# D1: Process Integrity (22%)
# ---------------------------------------------------------------------------

def _score_process_integrity(state, feature_dir):
    """
    Check each applicable gate: status is passed/skipped AND all artifacts
    exist with sufficient size.

    Returns int 0-100.
    """
    current_state = state.get("currentState", "")
    current_sn = _parse_state_num(current_state)
    if current_sn < 0:
        return None  # invalid state -> null

    gates = state.get("gates", [])
    mode = state.get("mode", "dual-agent")

    applicable_count = 0
    passed_count = 0

    for gate in gates:
        gate_id = gate.get("gateId", "")
        threshold = GATE_STATE_THRESHOLD.get(gate_id, 999)
        if current_sn < threshold:
            # Feature has not reached this gate's phase yet
            continue

        applicable_count += 1
        status = gate.get("status", "pending")

        # S9 + failed gate (not skipped) → short-circuit to 0
        if current_sn >= 9 and status == "failed":
            return 0

        # Check non-standard status values
        if status not in VALID_GATE_STATUSES:
            status = "failed"  # treat as failed

        status_ok = status in ("passed", "skipped")
        artifacts_ok = _check_gate_artifacts(gate, feature_dir, mode)

        if status_ok and artifacts_ok:
            passed_count += 1

    if applicable_count == 0:
        return 0

    return round(passed_count / applicable_count * 100)


def _check_gate_artifacts(gate, feature_dir, mode):
    """Check that all artifacts for a gate exist and meet minimum size."""
    artifacts = gate.get("artifacts", [])
    if not artifacts:
        return False

    gate_id = gate.get("gateId", "")

    # Gate 5 (reviews) has special handling
    if gate_id == "gate-5":
        return _check_review_artifacts(feature_dir, mode)

    for art_path in artifacts:
        full_path = os.path.join(feature_dir, art_path)
        if not os.path.isfile(full_path):
            return False
        size = _file_size(full_path)
        # Look up min size by basename
        basename = os.path.basename(art_path)
        min_size = ARTIFACT_MIN_SIZE.get(basename, 100)
        if size < min_size:
            return False

    return True


def _check_review_artifacts(feature_dir, mode):
    """Special handling for gate-5 reviews/ directory."""
    reviews_dir = os.path.join(feature_dir, "reviews")
    if not os.path.isdir(reviews_dir):
        return False

    md_files = glob_fn(os.path.join(reviews_dir, "*.md"))
    if not md_files:
        return False

    # At least one .md file must be >= 200 bytes
    has_valid = any(_file_size(f) >= 200 for f in md_files)
    if not has_valid:
        return False

    # In dual-agent mode, expect 2 files but 1 with valid content is enough
    # In single-agent mode, 1 valid file is enough
    return True


# ---------------------------------------------------------------------------
# D2: Review Quality (22%)
# ---------------------------------------------------------------------------

def _score_review_quality(state):
    """
    Count findings from grill-me and code-review sources.
    Apply density, severity, and coverage formulas.

    Returns int 0-100.
    """
    gates = state.get("gates", [])
    mode = state.get("mode", "dual-agent")

    all_findings = []
    for gate in gates:
        for f in gate.get("findings", []):
            all_findings.append(f)

    # Filter to review-relevant sources
    grill_findings = [f for f in all_findings if f.get("source") == "grill-me"]
    review_findings = [f for f in all_findings if f.get("source") == "code-review"]
    relevant = grill_findings + review_findings

    F = len(relevant)
    if F == 0:
        return 0

    # Severity counts
    def _count_sev(severity):
        return sum(1 for f in relevant if f.get("severity") == severity)

    P0 = _count_sev("P0")
    P1 = _count_sev("P1")
    P2 = _count_sev("P2")
    P3 = _count_sev("P3")

    # Density sub-score (max 50)
    density = min(F * 10, 50)

    # Severity sub-score (max 50)
    severity = min(P0 * 12 + P1 * 6 + P2 * 2 + P3 * 1, 50)

    # Coverage bonus
    has_grill = 1 if len(grill_findings) > 0 else 0
    has_review = 1 if len(review_findings) > 0 else 0
    coverage_bonus = (has_grill + has_review) * 5

    raw = density + severity + coverage_bonus

    if mode == "single-agent":
        return round(raw * 0.75)
    else:
        return min(100, raw)


# ---------------------------------------------------------------------------
# D3: Degradation Frequency (15%)
# ---------------------------------------------------------------------------

def _score_degradation_frequency(state):
    """
    Count fallback events and apply severity-weighted penalty matrix.

    Returns int 0-100.
    """
    fallback_events = state.get("fallbackEvents")
    if fallback_events is None:
        # null fallbackEvents -> assume no degradation, but warn
        return 100

    E = len(fallback_events)
    if E == 0:
        return 100

    # Count single-agent-mode resolutions
    SA = sum(1 for e in fallback_events if e.get("resolution") == "single-agent-mode")

    # Sum severity weights
    total_weight = 0
    for e in fallback_events:
        event_type = e.get("eventType", "")
        total_weight += FALLBACK_SEVERITY_WEIGHT.get(event_type, 0)

    penalty = min(total_weight * 6, 90)
    single_agent_penalty = SA * 5

    return max(10, 100 - penalty - single_agent_penalty)


# ---------------------------------------------------------------------------
# D4: Human Response Latency (10%)
# ---------------------------------------------------------------------------

def _score_human_latency(state):
    """
    Compute average response time of human decisions relative to gate entry.

    Returns int 0-100 or 50/80 for missing data cases.
    """
    human_decisions = state.get("humanDecisions", [])
    gates = state.get("gates", [])
    mode = state.get("mode", "dual-agent")
    feedback_loop = state.get("feedbackLoop", {})
    stalled_since = feedback_loop.get("stalledSince") if feedback_loop else None
    stalled_gate = feedback_loop.get("lastFailureGate") if feedback_loop else None

    # Build gate lookup by gateId
    gate_by_id = {g.get("gateId"): g for g in gates}

    if not human_decisions:
        # No human decisions
        passed_or_skipped = sum(
            1 for g in gates if g.get("status") in ("passed", "skipped")
        )
        if mode == "dual-agent" and passed_or_skipped >= 5:
            return 80
        else:
            return 50

    decision_scores = []
    for d in human_decisions:
        gate_id = d.get("gateId")
        made_at_str = d.get("madeAt")
        made_at = _iso_to_dt(made_at_str)

        # Check stalled override
        if (
            stalled_since is not None
            and stalled_gate is not None
            and gate_id == stalled_gate
        ):
            decision_scores.append(0)
            continue

        gate = gate_by_id.get(gate_id)
        entered_at_str = gate.get("enteredAt") if gate else None
        entered_at = _iso_to_dt(entered_at_str)

        if made_at is None or entered_at is None:
            decision_scores.append(50)  # unevaluable -> neutral
            continue

        latency_hours = (made_at - entered_at).total_seconds() / 3600.0
        if latency_hours < 0:
            # madeAt before enteredAt? treat as unevaluable
            decision_scores.append(50)
            continue

        if latency_hours <= 1:
            decision_scores.append(100)
        elif latency_hours <= 4:
            decision_scores.append(85)
        elif latency_hours <= 12:
            decision_scores.append(70)
        elif latency_hours <= 24:
            decision_scores.append(55)
        elif latency_hours <= 72:
            decision_scores.append(35)
        else:
            decision_scores.append(15)

    return round(sum(decision_scores) / len(decision_scores))


# ---------------------------------------------------------------------------
# D5: Experience Capture Rate (12%)
# ---------------------------------------------------------------------------

def _score_experience_capture(state, feature_dir):
    """
    Check ADR content structure, Retro content structure, and Pattern references.
    Only scored for features in S8 or S9.

    Returns int 0-100 or None.
    """
    current_state = state.get("currentState", "")
    if current_state not in ("S8", "S9"):
        return None

    feature_id = state.get("featureId", "")
    score = 0

    # --- ADR part (max 40) ---
    adr_path = os.path.join(feature_dir, "06-adr.md")
    if os.path.isfile(adr_path) and _file_size(adr_path) >= 100:
        score += 20
        content = _read_file(adr_path)
        if content:
            # Revisit Trigger detection
            if any(kw in content for kw in [
                "Revisit Trigger", "重新审视触发条件", "何时重新评估"
            ]):
                score += 10
            # Decision section detection
            if any(kw in content for kw in [
                "## Decision", "## 决策", "### Decision"
            ]):
                score += 5
            # Consequences section detection
            if any(kw in content for kw in [
                "## Consequences", "## 后果", "### 影响"
            ]):
                score += 5

    # --- Retro part (max 40) ---
    retro_path = os.path.join(feature_dir, "07-task-retro.md")
    if os.path.isfile(retro_path) and _file_size(retro_path) >= 100:
        score += 20
        content = _read_file(retro_path)
        if content:
            # Lessons detection
            if any(kw in content for kw in [
                "经验教训", "Lessons Learned", "## Lesson"
            ]):
                score += 10
            # Follow-up detection
            if any(kw in content for kw in [
                "Follow-up", "后续行动", "## Follow"
            ]):
                score += 5
            # Pattern detection in retro
            if any(kw in content for kw in [
                "Pattern", "模式", "## Pattern", "可复用"
            ]):
                score += 5

    # --- Pattern reference detection (20 points) ---
    # Check if any .md file in experience/patterns/ references this featureId
    if feature_id:
        # Resolve pattern dir relative to the eval script's parent (workflow/eval -> workflow)
        script_dir = Path(__file__).resolve().parent  # workflow/eval/
        workflow_dir = script_dir.parent  # workflow/
        pattern_dir = workflow_dir / "experience" / "patterns"
        if pattern_dir.is_dir():
            found = False
            for pattern_file in pattern_dir.glob("*.md"):
                content = _read_file(str(pattern_file))
                if content and feature_id in content:
                    found = True
                    break
            if found:
                score += 20

    return min(100, score)


# ---------------------------------------------------------------------------
# D6: Retry Success Rate (10%)
# ---------------------------------------------------------------------------

def _score_retry_success(state):
    """
    Calculate retry success rate from feedbackLoop.retryHistory.

    Returns int 0-100.
    """
    feedback_loop = state.get("feedbackLoop")

    # No feedbackLoop or never failed
    if feedback_loop is None:
        return 100

    retry_count = feedback_loop.get("retryCount", 0)
    last_failure = feedback_loop.get("lastFailure")
    retry_history = feedback_loop.get("retryHistory", [])

    if retry_count == 0 and last_failure is None:
        return 100

    # Has retry history
    if retry_history and len(retry_history) > 0:
        total = len(retry_history)
        passed = sum(1 for r in retry_history if r.get("result") == "passed")
        # failed_again and escalated are not passed
        # "retrying" status is ambiguous — treat as not-yet-passed

        success_rate = passed / total if total > 0 else 0.0
        base = round(success_rate * 80)

        # Feedback injection bonus
        bonus = 0
        if feedback_loop.get("feedbackInjected") is True:
            bonus += 10
        fb_source = feedback_loop.get("feedbackSource")
        if fb_source is not None and fb_source != "":
            bonus += 5
        fb_summary = feedback_loop.get("feedbackSummary")
        if fb_summary is not None and fb_summary != "":
            bonus += 5

        # Max retries penalty
        penalty = 0
        max_retries = feedback_loop.get("maxRetries", 3)
        if total > max_retries:
            penalty = (total - max_retries) * 10

        # Stall penalty
        stalled_since = feedback_loop.get("stalledSince")
        if stalled_since is not None:
            stalled_dt = _iso_to_dt(stalled_since)
            if stalled_dt is not None:
                now = datetime.now(timezone.utc)
                stall_hours = _hours_between(stalled_dt, now)
                if stall_hours is not None:
                    if stall_hours > 48:
                        penalty += 30
                    elif stall_hours > 24:
                        penalty += 15

        return max(0, min(100, base + bonus - penalty))

    # Has lastFailure but no retryHistory (failed but never retried)
    if last_failure is not None and (retry_history is None or len(retry_history) == 0):
        stalled_since = feedback_loop.get("stalledSince")
        if stalled_since is not None:
            stalled_dt = _iso_to_dt(stalled_since)
            if stalled_dt is not None:
                now = datetime.now(timezone.utc)
                stall_hours = _hours_between(stalled_dt, now)
                if stall_hours is not None:
                    if stall_hours > 48:
                        return 0
                    else:
                        return 30
        # Recently failed, not yet retried
        return 50

    return 100


# ---------------------------------------------------------------------------
# D7: Document Health (9%)
# ---------------------------------------------------------------------------

def _score_document_health(state, feature_dir):
    """
    Check ADR and Retro file sizes. Only scored for S8/S9.

    Returns int 0-100 or None.
    """
    current_state = state.get("currentState", "")
    if current_state not in ("S8", "S9"):
        return None

    adr_score = 0
    retro_score = 0

    # ADR scoring (0-50)
    adr_path = os.path.join(feature_dir, "06-adr.md")
    if os.path.isfile(adr_path):
        size = _file_size(adr_path)
        if size >= 500:
            adr_score = 50
        elif size >= 300:
            adr_score = 40
        elif size >= 100:
            adr_score = 25
        else:
            adr_score = 10

    # Retro scoring (0-50)
    retro_path = os.path.join(feature_dir, "07-task-retro.md")
    if os.path.isfile(retro_path):
        size = _file_size(retro_path)
        if size >= 500:
            retro_score = 50
        elif size >= 300:
            retro_score = 40
        elif size >= 100:
            retro_score = 25
        else:
            retro_score = 10

    return adr_score + retro_score


# ---------------------------------------------------------------------------
# Weighted Total & Grade
# ---------------------------------------------------------------------------

def _weighted_total(raw_scores, weights):
    """
    Compute weighted total from raw dimension scores.
    Handles null dimensions by redistributing their weight.

    Returns (total: int, dimensions: dict).
    """
    valid = {}
    null_dims = {}
    valid_weight_sum = 0.0

    for dim in DIMENSION_ORDER:
        score = raw_scores.get(dim)
        weight = weights.get(dim, 0.0)
        if score is None:
            null_dims[dim] = weight
        else:
            valid[dim] = (score, weight)
            valid_weight_sum += weight

    # If all null, total is null
    if valid_weight_sum == 0.0:
        return None, _build_dimensions_output(raw_scores, weights, {})

    # Compute redistribution scaling factor
    scaling_factor = 1.0 / valid_weight_sum if valid_weight_sum > 0 else 1.0

    total = 0.0
    adjusted = {}
    for dim, (score, weight) in valid.items():
        adj_weight = weight * scaling_factor
        adjusted[dim] = (score, weight, adj_weight, round(score * adj_weight, 1))
        total += score * adj_weight

    total = round(total)

    # Recompute weighted values for actual total (using original weights for display)
    dimensions_output = _build_dimensions_output(raw_scores, weights, adjusted)

    return total, dimensions_output


def _build_dimensions_output(raw_scores, weights, adjusted):
    """Build the dimensions dict for score.json output."""
    dims = {}
    for dim in DIMENSION_ORDER:
        score = raw_scores.get(dim)
        weight = weights.get(dim, 0.0)

        if score is None:
            dims[dim] = {
                "score": None,
                "weight": weight,
                "weighted": 0.0,
                "status": "null_not_applicable",
            }
        elif dim in adjusted:
            _, _, adj_w, weighted = adjusted[dim]
            dims[dim] = {
                "score": score,
                "weight": weight,
                "weighted": weighted,
                "status": "scored",
            }
        else:
            # Scored but in a group where some dims are null (all valid case)
            # Actually, adjusted only contains non-null dims
            dims[dim] = {
                "score": score,
                "weight": weight,
                "weighted": round(score * weight, 1),
                "status": "scored",
            }

    return dims


def _grade(total):
    """Map numeric score to letter grade."""
    if total is None:
        return None
    if total >= 85:
        return "A"
    elif total >= 70:
        return "B"
    elif total >= 55:
        return "C"
    elif total >= 40:
        return "D"
    else:
        return "F"


# ---------------------------------------------------------------------------
# Baseline Comparison
# ---------------------------------------------------------------------------

def _compare_baseline(total, raw_scores, baseline):
    """
    Compare feature score against baseline.
    Returns a baselineComparison dict or None.
    """
    if baseline is None:
        return None

    current = baseline.get("currentBaseline")
    if current is None:
        return {"status": "no_baseline", "delta": None, "dimensionDeltas": {}}

    baseline_total = current.get("totalScore")
    baseline_dims = current.get("dimensions", {})

    if baseline_total is None:
        return {"status": "no_baseline", "delta": None, "dimensionDeltas": {}}

    delta = (total or 0) - baseline_total if total is not None else None
    dim_deltas = {}
    for dim in DIMENSION_ORDER:
        fd = raw_scores.get(dim)
        bd = baseline_dims.get(dim)
        if fd is not None and bd is not None:
            dim_deltas[dim] = fd - bd
        else:
            dim_deltas[dim] = None

    if delta is None:
        status = "no_baseline"
    elif delta >= 5:
        status = "above_baseline"
    elif delta <= -5:
        status = "below_baseline"
    else:
        status = "at_baseline"

    return {
        "baselineVersion": baseline.get("version", "unknown"),
        "baselineTotal": baseline_total,
        "delta": delta,
        "status": status,
        "dimensionDeltas": dim_deltas,
    }


# ---------------------------------------------------------------------------
# Warnings Collection
# ---------------------------------------------------------------------------

def _collect_warnings(state, raw_scores, feature_dir):
    """Collect all warnings from the scoring process."""
    warnings = []
    current_state = state.get("currentState", "")
    feature_id = state.get("featureId", "")
    gates = state.get("gates", [])
    fallback_events = state.get("fallbackEvents")
    state_history = state.get("stateHistory", [])

    # Check gates length
    if len(gates) != 7:
        warnings.append({
            "dimension": "processIntegrity",
            "code": "GATES_COUNT_MISMATCH",
            "message": f"gates[] 长度为 {len(gates)}，期望 7",
            "severity": "P2",
        })

    # Check non-standard gate statuses
    for g in gates:
        if g.get("status") not in VALID_GATE_STATUSES:
            warnings.append({
                "dimension": "processIntegrity",
                "code": "INVALID_GATE_STATUS",
                "message": f"{g.get('gateId')} 的 status '{g.get('status')}' 非标准枚举值，视为 failed",
                "severity": "P2",
            })

    # Check null fallbackEvents
    if fallback_events is None:
        warnings.append({
            "dimension": "degradationFrequency",
            "code": "FALLBACK_EVENTS_NULL",
            "message": "fallbackEvents 为 null，假设无降级事件",
            "severity": "P3",
        })

    # Check empty stateHistory
    if not state_history:
        warnings.append({
            "dimension": None,
            "code": "STATE_HISTORY_EMPTY",
            "message": "stateHistory 为空，无法验证状态转换轨迹",
            "severity": "P2",
        })

    # D5/D7: pattern references not found
    if current_state in ("S8", "S9"):
        # Check for pattern references (reuse logic from D5)
        if feature_id:
            script_dir = Path(__file__).resolve().parent
            workflow_dir = script_dir.parent
            pattern_dir = workflow_dir / "experience" / "patterns"
            found = False
            if pattern_dir.is_dir():
                for pattern_file in pattern_dir.glob("*.md"):
                    content = _read_file(str(pattern_file))
                    if content and feature_id in content:
                        found = True
                        break
            if not found:
                warnings.append({
                    "dimension": "experienceCaptureRate",
                    "code": "NO_PATTERN_FOUND",
                    "message": "未在 experience/patterns/ 目录找到引用本功能的 Pattern 文件",
                    "severity": "P3",
                })

        # Check ADR existence
        adr_path = os.path.join(feature_dir, "06-adr.md")
        if not os.path.isfile(adr_path):
            warnings.append({
                "dimension": "documentHealth",
                "code": "ADR_MISSING",
                "message": "06-adr.md 不存在，尽管功能已进入 S8/S9",
                "severity": "P2",
            })

        # Check Retro existence
        retro_path = os.path.join(feature_dir, "07-task-retro.md")
        if not os.path.isfile(retro_path):
            warnings.append({
                "dimension": "documentHealth",
                "code": "RETRO_MISSING",
                "message": "07-task-retro.md 不存在，尽管功能已进入 S8/S9",
                "severity": "P2",
            })

    return warnings


# ---------------------------------------------------------------------------
# Raw Inputs Collection
# ---------------------------------------------------------------------------

def _collect_raw_inputs(state, raw_scores, feature_dir):
    """Collect all raw inputs used in scoring for auditability."""
    gates = state.get("gates", [])
    feedback_loop = state.get("feedbackLoop") or {}
    fallback_events = state.get("fallbackEvents") or []
    human_decisions = state.get("humanDecisions") or []

    # Count findings by source
    all_findings = []
    for g in gates:
        for f in g.get("findings", []):
            all_findings.append(f)

    grill_findings = [f for f in all_findings if f.get("source") == "grill-me"]
    review_findings = [f for f in all_findings if f.get("source") == "code-review"]
    relevant = grill_findings + review_findings

    p0 = sum(1 for f in relevant if f.get("severity") == "P0")
    p1 = sum(1 for f in relevant if f.get("severity") == "P1")

    # Fallback severity weight
    severity_weight_sum = sum(
        FALLBACK_SEVERITY_WEIGHT.get(e.get("eventType", ""), 0)
        for e in fallback_events
    )
    sa_count = sum(1 for e in fallback_events if e.get("resolution") == "single-agent-mode")

    # Human decision latency
    gate_by_id = {g.get("gateId"): g for g in gates}
    latencies = []
    for d in human_decisions:
        gate = gate_by_id.get(d.get("gateId"))
        made_at = _iso_to_dt(d.get("madeAt"))
        entered_at = _iso_to_dt(gate.get("enteredAt")) if gate else None
        if made_at and entered_at:
            h = (made_at - entered_at).total_seconds() / 3600.0
            if h >= 0:
                latencies.append(h)

    avg_latency = round(sum(latencies) / len(latencies), 1) if latencies else None

    # Artifacts presence
    current_state = state.get("currentState", "")
    current_sn = _parse_state_num(current_state)
    artifacts_present = 0
    artifacts_expected = 0
    for g in gates:
        gate_id = g.get("gateId", "")
        threshold = GATE_STATE_THRESHOLD.get(gate_id, 999)
        if current_sn >= 0 and current_sn >= threshold:
            for art in g.get("artifacts", []):
                artifacts_expected += 1
                full_path = os.path.join(feature_dir, art)
                if os.path.isfile(full_path):
                    artifacts_present += 1

    # Retry stats
    retry_history = feedback_loop.get("retryHistory", [])
    retry_total = len(retry_history)
    retry_success = sum(1 for r in retry_history if r.get("result") == "passed")

    # Stall check
    stalled_since = feedback_loop.get("stalledSince")
    stalled_hours = None
    if stalled_since:
        stalled_dt = _iso_to_dt(stalled_since)
        if stalled_dt:
            now = datetime.now(timezone.utc)
            stalled_hours = round(_hours_between(stalled_dt, now), 1)

    # ADR / Retro presence
    adr_path = os.path.join(feature_dir, "06-adr.md")
    retro_path = os.path.join(feature_dir, "07-task-retro.md")
    adr_exists = os.path.isfile(adr_path)
    retro_exists = os.path.isfile(retro_path)

    # Pattern references
    feature_id = state.get("featureId", "")
    pattern_refs = 0
    if feature_id:
        script_dir = Path(__file__).resolve().parent
        workflow_dir = script_dir.parent
        pattern_dir = workflow_dir / "experience" / "patterns"
        if pattern_dir.is_dir():
            for pattern_file in pattern_dir.glob("*.md"):
                content = _read_file(str(pattern_file))
                if content and feature_id in content:
                    pattern_refs += 1

    return {
        "featureId": feature_id,
        "currentState": current_state,
        "mode": state.get("mode", "unknown"),
        "gatesPassed": sum(1 for g in gates if g.get("status") == "passed"),
        "gatesSkipped": sum(1 for g in gates if g.get("status") == "skipped"),
        "gatesApplicable": sum(
            1 for g in gates
            if current_sn >= GATE_STATE_THRESHOLD.get(g.get("gateId", ""), 999)
        ) if current_sn >= 0 else 0,
        "artifactsPresent": artifacts_present,
        "artifactsExpected": artifacts_expected,
        "reviewFindingsGrillMe": len(grill_findings),
        "reviewFindingsCodeReview": len(review_findings),
        "reviewP0Count": p0,
        "reviewP1Count": p1,
        "fallbackEventCount": len(fallback_events),
        "fallbackSeverityWeight": severity_weight_sum,
        "singleAgentSwitchCount": sa_count,
        "humanDecisionCount": len(human_decisions),
        "humanDecisionAvgLatencyHours": avg_latency,
        "retroExists": retro_exists,
        "retroSizeBytes": _file_size(retro_path) if retro_exists else 0,
        "adrExists": adr_exists,
        "adrSizeBytes": _file_size(adr_path) if adr_exists else 0,
        "patternReferencesFound": pattern_refs,
        "retryTotal": retry_total,
        "retrySuccess": retry_success,
        "feedbackInjected": feedback_loop.get("feedbackInjected", False),
        "stalledHours": stalled_hours,
    }


# ---------------------------------------------------------------------------
# Null Score (feature-state.json missing or unparseable)
# ---------------------------------------------------------------------------

def _null_score(feature_id, reason):
    """Return a null score object when feature-state.json is unavailable."""
    dims = {}
    for dim in DIMENSION_ORDER:
        dims[dim] = {
            "score": None,
            "weight": WEIGHTS.get(dim, 0.0),
            "weighted": 0.0,
            "status": "null_missing_data",
        }

    return {
        "engine": "scoring-engine-v1",
        "scoredAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scoredBy": "script:score.py",
        "featureId": feature_id,
        "llmCalls": 0,
        "deterministicHash": None,
        "scores": {
            "total": None,
            "grade": None,
            "dimensions": dims,
        },
        "baselineComparison": None,
        "warnings": [
            {
                "dimension": None,
                "code": "FEATURE_STATE_UNAVAILABLE",
                "message": reason,
                "severity": "P0",
            }
        ],
        "rawInputs": {
            "featureId": feature_id,
            "currentState": None,
        },
    }


# ---------------------------------------------------------------------------
# Main scoring function for a single feature
# ---------------------------------------------------------------------------

def score_feature(feature_dir, baseline=None):
    """
    Score a single feature given its folder path.

    Args:
        feature_dir: Path to the feature folder (must contain feature-state.json).
        baseline: Optional baseline dict loaded from baselines.json.

    Returns:
        dict: The score.json object.
    """
    feature_dir = Path(feature_dir)
    feature_id = feature_dir.name
    state_path = feature_dir / "feature-state.json"

    # Check feature-state.json exists
    if not state_path.is_file():
        return _null_score(feature_id, f"feature-state.json 不存在: {state_path}")

    # Parse feature-state.json
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        return _null_score(feature_id, f"feature-state.json 解析失败: {e}")

    feature_id = state.get("featureId", feature_id)

    # Compute all dimension scores
    raw_scores = {}
    raw_scores["processIntegrity"] = _score_process_integrity(state, str(feature_dir))
    raw_scores["reviewQuality"] = _score_review_quality(state)
    raw_scores["degradationFrequency"] = _score_degradation_frequency(state)
    raw_scores["humanResponseLatency"] = _score_human_latency(state)
    raw_scores["experienceCaptureRate"] = _score_experience_capture(state, str(feature_dir))
    raw_scores["retrySuccessRate"] = _score_retry_success(state)
    raw_scores["documentHealth"] = _score_document_health(state, str(feature_dir))

    # Compute weighted total
    total, dimensions = _weighted_total(raw_scores, WEIGHTS)

    # Deterministic hash
    hash_parts = [feature_id]
    for dim in DIMENSION_ORDER:
        val = raw_scores.get(dim)
        hash_parts.append(str(val) if val is not None else "null")
    hash_input = "|".join(hash_parts)
    det_hash = hashlib.sha256(hash_input.encode("utf-8")).hexdigest()[:12]

    # Baseline comparison
    baseline_comparison = _compare_baseline(total, raw_scores, baseline)

    # Warnings
    warnings = _collect_warnings(state, raw_scores, str(feature_dir))

    # Post-scoring: quality-watch if total < baseline - 15
    if baseline_comparison and baseline_comparison.get("status") not in (None, "no_baseline"):
        b_total = baseline_comparison.get("baselineTotal", 0)
        if total is not None and total < b_total - 15:
            warnings.append({
                "dimension": None,
                "code": "QUALITY_WATCH",
                "message": f"总分 {total} 低于基线 {b_total} 超过 15 分，标记 quality-watch",
                "severity": "P1",
            })

    # Post-scoring: experiencePipeline stats for S8/S9
    current_state = state.get("currentState", "")
    if current_state in ("S8", "S9"):
        # Check experience pipeline health
        script_dir = Path(__file__).resolve().parent
        workflow_dir = script_dir.parent
        experience_dir = workflow_dir / "experience"
        lessons_dir = experience_dir / "lessons"
        patterns_dir = experience_dir / "patterns"
        instincts_dir = experience_dir / "instincts"

        exp_stats = {
            "lessonsCount": len(list(lessons_dir.glob("*.md"))) if lessons_dir.is_dir() else 0,
            "patternsCount": len(list(patterns_dir.glob("*.md"))) if patterns_dir.is_dir() else 0,
            "instinctsCount": len(list(instincts_dir.glob("*.md"))) if instincts_dir.is_dir() else 0,
        }
        # Add to rawInputs
        pass  # rawInputs is built below; we'll add this

    # Raw inputs
    raw_inputs = _collect_raw_inputs(state, raw_scores, str(feature_dir))

    # Add experience pipeline stats for S8/S9
    if current_state in ("S8", "S9"):
        script_dir = Path(__file__).resolve().parent
        workflow_dir = script_dir.parent
        experience_dir = workflow_dir / "experience"
        lessons_dir = experience_dir / "lessons"
        patterns_dir = experience_dir / "patterns"
        instincts_dir = experience_dir / "instincts"
        raw_inputs["experiencePipeline"] = {
            "lessonsCount": len(list(lessons_dir.glob("*.md"))) if lessons_dir.is_dir() else 0,
            "patternsCount": len(list(patterns_dir.glob("*.md"))) if patterns_dir.is_dir() else 0,
            "instinctsCount": len(list(instincts_dir.glob("*.md"))) if instincts_dir.is_dir() else 0,
        }

    return {
        "engine": "scoring-engine-v1",
        "scoredAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scoredBy": "script:score.py",
        "featureId": feature_id,
        "llmCalls": 0,
        "deterministicHash": det_hash,
        "scores": {
            "total": total,
            "grade": _grade(total),
            "dimensions": dimensions,
        },
        "baselineComparison": baseline_comparison,
        "warnings": warnings,
        "rawInputs": raw_inputs,
    }


# ---------------------------------------------------------------------------
# All-features scoring
# ---------------------------------------------------------------------------

def score_all_features(workflow_root, baseline=None, output_dir=None):
    """
    Score all features under workflow/features/.

    Args:
        workflow_root: Path to the workflow/ directory.
        baseline: Optional baseline dict.
        output_dir: Optional output directory for score.json files (default: feature folders).

    Returns:
        list of score dicts.
    """
    features_dir = Path(workflow_root) / "features"
    if not features_dir.is_dir():
        print(f"Error: features directory not found: {features_dir}", file=sys.stderr)
        return []

    results = []
    for feature_dir in sorted(features_dir.iterdir()):
        if not feature_dir.is_dir():
            continue
        state_file = feature_dir / "feature-state.json"
        if not state_file.is_file():
            continue

        score = score_feature(str(feature_dir), baseline)
        results.append(score)

        # Write output
        if output_dir:
            out_path = Path(output_dir) / f"{feature_dir.name}-score.json"
            out_path.parent.mkdir(parents=True, exist_ok=True)
        else:
            out_path = feature_dir / "score.json"

        out_path.write_text(
            json.dumps(score, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"Scored {feature_dir.name}: total={score['scores']['total']}, "
              f"grade={score['scores']['grade']} -> {out_path}")

    return results


# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Deterministic Scoring Engine — scores feature workflow health.",
    )
    parser.add_argument(
        "--feature",
        type=str,
        help="Feature ID to score (single feature mode).",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Score all features under workflow/features/.",
    )
    parser.add_argument(
        "--baseline",
        type=str,
        default=None,
        help="Path to baselines.json (optional).",
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Output path for score.json (single feature mode).",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default=None,
        help="Output directory for score.json files (--all mode).",
    )

    args = parser.parse_args()

    if not args.feature and not args.all:
        parser.print_help()
        print("\nError: must specify --feature or --all", file=sys.stderr)
        sys.exit(1)

    # Resolve workflow root
    # This script is at workflow/eval/score.py, so workflow/ is ../ from __file__
    script_dir = Path(__file__).resolve().parent  # workflow/eval/
    workflow_root = script_dir.parent  # workflow/

    # Load baseline if provided
    baseline = None
    if args.baseline:
        baseline_path = Path(args.baseline)
        if baseline_path.is_file():
            try:
                baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError) as e:
                print(f"Warning: could not parse baseline file: {e}", file=sys.stderr)
        else:
            # Try default path: workflow/eval/baselines.json
            default_baseline = script_dir / "baselines.json"
            if args.baseline == str(default_baseline) or not Path(args.baseline).is_absolute():
                # Look relative to workflow/eval/
                candidate = script_dir / args.baseline
                if candidate.is_file():
                    try:
                        baseline = json.loads(candidate.read_text(encoding="utf-8"))
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        pass
            if baseline is None:
                print(f"Warning: baseline file not found: {args.baseline}", file=sys.stderr)
    else:
        # Try default baseline path
        default_baseline = script_dir / "baselines.json"
        if default_baseline.is_file():
            try:
                baseline = json.loads(default_baseline.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                pass

    if args.all:
        results = score_all_features(
            str(workflow_root),
            baseline=baseline,
            output_dir=args.output_dir,
        )
        if not results:
            print("No features found to score.", file=sys.stderr)
            sys.exit(0)
        # Print summary
        totals = [r["scores"]["total"] for r in results if r["scores"]["total"] is not None]
        if totals:
            print(f"\nSummary: {len(results)} features scored, "
                  f"avg={round(sum(totals)/len(totals))}, "
                  f"min={min(totals)}, max={max(totals)}")
        else:
            print(f"\nSummary: {len(results)} features processed, all returned null scores")
    else:
        feature_dir = workflow_root / "features" / args.feature
        if not feature_dir.is_dir():
            print(f"Error: feature directory not found: {feature_dir}", file=sys.stderr)
            sys.exit(1)

        result = score_feature(str(feature_dir), baseline)

        # Write output
        if args.output:
            out_path = Path(args.output)
        else:
            out_path = feature_dir / "score.json"

        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        print(f"Scored {args.feature}: total={result['scores']['total']}, "
              f"grade={result['scores']['grade']}")
        print(f"Output: {out_path}")

        if result.get("warnings"):
            print(f"Warnings: {len(result['warnings'])}")
            for w in result["warnings"]:
                print(f"  [{w.get('code')}] {w.get('message')}")

        # Print to stdout for pipeline consumption
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
