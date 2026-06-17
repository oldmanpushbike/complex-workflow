#!/usr/bin/env python3
"""
workflow/eval/score.py -- Deterministic Scoring Engine v2

Scores a feature's product trustworthiness, code verifiability, and security
compliance using only arithmetic and filesystem checks. Zero LLM calls, zero
network requests. 3 runs produce identical SHA256 hashes.

Three-layer defense architecture:
  Layer 1 — Product Trustworthiness (D1+D2, 38%)
  Layer 2 — Code Verifiability   (D3+D4+D6+D7, 46%)
  Layer 3 — Security Compliance  (D5, 16%) + one-vote veto

Usage:
    python score.py --feature <feature-id> [--baseline <baselines.json>] [--output <score.json>]
    python score.py --all [--baseline <baselines.json>] [--output-dir <dir>]
    python score.py --feature <feature-id> --live-check

Constraints:
    - Python 3.8+
    - Stdlib only: json, os, sys, hashlib, datetime, pathlib, glob, re
    - No LLM SDK imports, no network requests
"""

import json
import os
import sys
import hashlib
import re
import argparse
from datetime import datetime, timezone
from pathlib import Path
from glob import glob as glob_fn


# ============================================================================
# Constants
# ============================================================================

# v2 weights (from scoring-engine.md unified v2)
WEIGHTS = {
    "processIntegrity": 0.20,
    "artifactQuality": 0.18,
    "codeCorrectness": 0.18,
    "efficiency": 0.08,
    "securityCompliance": 0.16,
    "iterationCapability": 0.12,
    "interfaceAcceptance": 0.08,
}

DIMENSION_ORDER = [
    "processIntegrity",
    "artifactQuality",
    "codeCorrectness",
    "efficiency",
    "securityCompliance",
    "iterationCapability",
    "interfaceAcceptance",
]

# Gate -> minimum S-state number
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

# Valid enum values
VALID_GATE_STATUSES = {"pending", "passed", "failed", "skipped"}
VALID_STATES = {"S0", "S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8", "S9"}

# Legal state transitions (state-machine.md)
LEGAL_FORWARD = {
    ("S0", "S1"), ("S1", "S2"), ("S2", "S3"), ("S3", "S4"),
    ("S4", "S5"), ("S5", "S6"), ("S6", "S7"), ("S7", "S8"), ("S8", "S9"),
}
LEGAL_ROLLBACK = {
    ("S2", "S1"), ("S3", "S1"), ("S3", "S3"), ("S5", "S5"),
    ("S6", "S6"), ("S6", "S3"), ("S7", "S7"), ("S7", "S5"),
    ("S7", "S3"), ("S8", "S8"),
}
LEGAL_TRANSITIONS = LEGAL_FORWARD | LEGAL_ROLLBACK

# Token baselines per complexity
TOKEN_BASELINE = {
    "low": 50000,
    "medium": 150000,
    "high": 350000,
    "epic": 800000,
}

# Stage ideal hours (cumulative)
# S0-S2: 2h, S3-S5: +4h, S6-S7: +2h, S8-S9: +1h  => 9h total
STAGE_IDEAL_HOURS_MAP = {2: 2, 5: 6, 7: 8, 9: 9}


# ============================================================================
# D1: Preset Rules (24 rules, gate-check.sh compatible)
# ============================================================================

# Each rule: (gate_id, artifact_file, candidates: list of fixed strings)
# Rule is hit if ANY candidate appears in the first 100 lines of the file.
PRESET_RULES = [
    # Gate 1 — 01-openspec-proposal.md (6 rules)
    ("gate-1", "01-openspec-proposal.md", ["目标", "Goal"]),
    ("gate-1", "01-openspec-proposal.md", ["非目标", "Non-Goal"]),
    ("gate-1", "01-openspec-proposal.md", ["验收", "Acceptance"]),
    ("gate-1", "01-openspec-proposal.md", ["用户", "User"]),
    ("gate-1", "01-openspec-proposal.md", ["决策日志", "Decision Log", "Decision"]),
    ("gate-1", "01-openspec-proposal.md", ["回滚", "Rollback", "迁移", "Migration"]),
    # Gate 2 — 02-grill-me-report.md (3 rules)
    ("gate-2", "02-grill-me-report.md", ["P0", "P1", "Finding", "风险", "Severity"]),
    ("gate-2", "02-grill-me-report.md", ["Accepted", "Residual", "接受", "残留"]),
    ("gate-2", "02-grill-me-report.md", ["Source:", "来源", "grill-me", "manual-grill"]),
    # Gate 3 — 03-task-skill-map.md (3 rules)
    ("gate-3", "03-task-skill-map.md", ["Task ID", "|"]),
    ("gate-3", "03-task-skill-map.md", ["Skill", "技能", "route"]),
    ("gate-3", "03-task-skill-map.md", ["Rollback", "回滚"]),
    # Gate 4 — 04-implementation-plan.md (2 rules)
    ("gate-4", "04-implementation-plan.md", ["Approved Scope", "批准", "Task ID"]),
    ("gate-4", "04-implementation-plan.md", ["Actual", "实际", "Files To Touch"]),
    # Gate 5 — reviews/*.md (2 rules)
    ("gate-5", "reviews/", ["dual-agent", "single-agent"]),
    ("gate-5", "reviews/", ["Final Review", "Decision:", "审查决定"]),
    # Gate 6 — 05-verification-log.md (4 rules)
    ("gate-6", "05-verification-log.md", ["Acceptance", "验收"]),
    ("gate-6", "05-verification-log.md", ["Test", "测试", "Unit", "Integration", "Manual"]),
    ("gate-6", "05-verification-log.md", ["Residual Risk", "残余风险"]),
    ("gate-6", "05-verification-log.md", ["Ship", "Hold", "最终决定"]),
    # Gate 7 — 06-adr.md (2 rules) + 07-task-retro.md (2 rules) = 4 rules
    ("gate-7", "06-adr.md", ["Context", "Decision"]),
    ("gate-7", "06-adr.md", ["Revisit", "重新审视", "Trigger"]),
    ("gate-7", "07-task-retro.md", ["What Worked", "What Failed", "可复用", "成功", "失败"]),
    ("gate-7", "07-task-retro.md", ["Follow-Up", "后续", "Knowledge"]),
]


# ============================================================================
# D2: Structure Rules (S01-S07) applicability matrix
# ============================================================================

# Each entry: (rule_id, file_basename)
# For gate-5 (reviews/), the file basename is None (special handling)
STRUCTURE_RULES_MATRIX = [
    # S01: code blocks (```...```) — 01-openspec, 04-impl-plan, 05-verify
    ("S01", "01-openspec-proposal.md"),
    ("S01", "04-implementation-plan.md"),
    ("S01", "05-verification-log.md"),
    # S02: file path refs — 01-openspec, 03-task-map, 04-impl-plan
    ("S02", "01-openspec-proposal.md"),
    ("S02", "03-task-skill-map.md"),
    ("S02", "04-implementation-plan.md"),
    # S03: markdown tables — 01-openspec, 02-grill-me, 03-task-map
    ("S03", "01-openspec-proposal.md"),
    ("S03", "02-grill-me-report.md"),
    ("S03", "03-task-skill-map.md"),
    # S04: risk checklist — 02-grill-me, 05-verify
    ("S04", "02-grill-me-report.md"),
    ("S04", "05-verification-log.md"),
    # S05: rollback plan — 01-openspec, 03-task-map, 07-retro
    ("S05", "01-openspec-proposal.md"),
    ("S05", "03-task-skill-map.md"),
    ("S05", "07-task-retro.md"),
    # S06: numbered lists — 01-openspec, 02-grill-me, 03-task-map, 04-impl-plan, 06-adr, 07-retro
    ("S06", "01-openspec-proposal.md"),
    ("S06", "02-grill-me-report.md"),
    ("S06", "03-task-skill-map.md"),
    ("S06", "04-implementation-plan.md"),
    ("S06", "06-adr.md"),
    ("S06", "07-task-retro.md"),
    # S07: size >= 500B — 01-openspec, 02-grill-me, 03-task-map, 04-impl-plan
    ("S07", "01-openspec-proposal.md"),
    ("S07", "02-grill-me-report.md"),
    ("S07", "03-task-skill-map.md"),
    ("S07", "04-implementation-plan.md"),
]


# ============================================================================
# D2: Anti-waterfill — file max scores
# ============================================================================

ANTI_WATER_MAX_SCORES = {
    "01-openspec-proposal.md": 8,
    "02-grill-me-report.md": 6,
    "03-task-skill-map.md": 6,
    "04-implementation-plan.md": 4,
    "05-verification-log.md": 4,
    "06-adr.md": 6,
    "07-task-retro.md": 6,
}


# ============================================================================
# D2: Template Fingerprints (hardcoded, pre-computed from templates/)
# ============================================================================

TEMPLATE_FINGERPRINTS = {
    "01-openspec-proposal.md": [
        "## OpenSpec 提案",
        "| 字段 | 值 |",
        "## 问题",
        "## 目标",
        "## 非目标",
        "## 设计决策（需人类审批）",
        "> <strong>Gate 1 签核清单。</strong>以下是从提案中提取的",
        "<details open>",
        "<summary><strong>📋 背景</strong></summary>",
        "<details open>",
        "<summary><strong>🔍 分析</strong></summary>",
        "<details>",
        "<summary><strong>📚 经验课堂</strong></summary>",
        "<strong>✋ 人类决策：</strong> <em>[待填写]</em>",
        "| 简述 |",
        "| 优势 |",
        "| 风险 |",
        "| 成本 |",
        "## 用户与角色",
        "## 当前行为",
        "## 目标行为",
        "## 用户流程",
        "Given:",
        "When:",
        "Then:",
        "## 数据模型",
        "## API / 接口契约",
        "## 权限与安全",
        "## 迁移 / 回滚",
        "## 验收标准",
        "- [ ]",
        "## 验证计划",
        "## 待解决问题",
        "## 决策日志",
        "| 日期 | 决策 | 理由 | 负责人 |",
    ],
    "02-grill-me-report.md": [
        "## grill-me Report",
        "## Summary",
        "> **Note:** Design decisions (scale, style, tech stack, scope, user role)",
        "## Challenge Questions",
        "### Edge Cases",
        "### Security And Privacy",
        "### Data And Migration",
        "### Performance And Scale",
        "### Testing",
        "## Findings",
        "| ID | Severity | Finding | Required response | Status |",
        "## Spec Amendments Needed",
        "## Accepted Residual Risks",
        "| Risk | Why accepted | Owner | Review date |",
        "- What happens when inputs are empty, duplicated, malformed, stale, or too large?",
        "- What happens on retry, refresh, cancel, undo, or partial failure?",
    ],
    "03-task-skill-map.md": [
        "## Task + Skill Map",
        "## Routing Principles",
        "## Task Map",
        "| Task ID | Task | Owner | Skill route | Likely files | Test plan | Rollback note | Status |",
        "## Suggested Skill Categories",
        "## Skill Invocation Notes",
        "## Unrouted Tasks",
        "| Task | Why unrouted | Decision needed |",
        "- Use the narrowest useful skill.",
        "- Use specialist skills for domains where correctness depends on expert patterns.",
    ],
    "04-implementation-plan.md": [
        "## Implementation Plan",
        "## Approved Scope",
        "## Files To Touch",
        "## Implementation Notes",
        "## Rollback",
    ],
    "05-verification-log.md": [
        "## Verification Log",
        "## Acceptance Criteria",
        "## Test Results",
        "## Residual Risks",
        "## Final Decision",
    ],
    "06-adr.md": [
        "## ADR",
        "## Context",
        "## Decision",
        "## Consequences",
        "## Revisit Trigger",
    ],
    "07-task-retro.md": [
        "## Task Retro",
        "## What Worked",
        "## What Failed",
        "## Reusable Patterns",
        "## Follow-Up",
        "## Knowledge To Carry",
    ],
}

# Placeholder markers for shell_ratio detection
PLACEHOLDER_MARKERS = [
    "TBD", "待填写", "TODO", "<填写", "<your", "N/A",
    "​",  # zero-width space
    "[待填写]", "<em>[待填写]</em>",
]


# ============================================================================
# Helpers (reused from v1 + new)
# ============================================================================

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
        s = iso_str.replace("Z", "+00:00")
        return datetime.fromisoformat(s)
    except (ValueError, TypeError):
        return None


def _hours_between(dt_a, dt_b):
    """Return absolute hours between two datetimes, or None."""
    if dt_a is None or dt_b is None:
        return None
    return abs((dt_a - dt_b).total_seconds()) / 3600.0


def _read_file(path, max_lines=None):
    """Read file contents as string. Returns None on failure."""
    try:
        p = Path(path)
        if not p.is_file():
            return None
        text = p.read_text(encoding="utf-8", errors="replace")
        if max_lines is not None:
            lines = text.split("\n")[:max_lines]
            text = "\n".join(lines)
        return text
    except (OSError, UnicodeDecodeError):
        return None


def _file_size(path):
    """Return file size in bytes, or 0 if missing/unreadable."""
    try:
        return Path(path).stat().st_size
    except OSError:
        return 0


def _get_applicable_gates(state):
    """Return gates that the feature has reached based on currentState."""
    current_state = state.get("currentState", "")
    current_sn = _parse_state_num(current_state)
    if current_sn < 0:
        return []
    gates = state.get("gates", [])
    applicable = []
    for gate in gates:
        gate_id = gate.get("gateId", "")
        threshold = GATE_STATE_THRESHOLD.get(gate_id, 999)
        if current_sn >= threshold:
            applicable.append(gate)
    return applicable


def _get_applicable_files(state):
    """Return list of artifact filenames for all applicable gates."""
    files = set()
    for gate in _get_applicable_gates(state):
        for art in gate.get("artifacts", []):
            basename = os.path.basename(art)
            if basename:
                files.add(basename)
    # Handle gate-5 reviews/ specially
    if any(g.get("gateId") == "gate-5" and g in _get_applicable_gates(state)
           for g in state.get("gates", [])):
        files.discard("")  # reviews/ expands to individual .md files
    return sorted(files)


def _check_preset_rule(feature_dir, artifact_file, candidates):
    """Check if a preset rule matches. Returns True if any candidate found."""
    full_path = os.path.join(feature_dir, artifact_file)
    if not os.path.isfile(full_path):
        return False
    # Read first 100 lines
    content = _read_file(full_path, max_lines=100)
    if content is None:
        return False
    for candidate in candidates:
        if candidate in content:
            return True
    return False


def _check_preset_rule_reviews(feature_dir, candidates):
    """Check a preset rule against all .md files in reviews/ directory."""
    reviews_dir = os.path.join(feature_dir, "reviews")
    if not os.path.isdir(reviews_dir):
        return False
    for md_file in glob_fn(os.path.join(reviews_dir, "*.md")):
        content = _read_file(md_file, max_lines=100)
        if content is None:
            continue
        for candidate in candidates:
            if candidate in content:
                return True
    return False


def _check_structure_rule(rule_id, file_path):
    """Check a single structure rule against a file. Returns bool."""
    content = _read_file(file_path, max_lines=200)
    if content is None:
        return False

    if rule_id == "S01":
        # At least one code block (need ``` opening and closing)
        return content.count("```") >= 2
    elif rule_id == "S02":
        # At least 3 file path references
        count = len(re.findall(
            r'\.(?:ts|js|py|java|go|rs|cpp|h|css|html|vue|tsx|jsx|json|yaml|yml|toml|md|sql|sh|bash)\b|Dockerfile|Makefile',
            content
        ))
        return count >= 3
    elif rule_id == "S03":
        # At least 1 markdown table row
        return bool(re.search(r'^\|.*\|.*\|$', content, re.MULTILINE))
    elif rule_id == "S04":
        # Risk/Risk/P0/P1/P2/P3 at least 2 lines
        count = len(re.findall(r'(风险|Risk|P0|P1|P2|P3)', content))
        return count >= 2
    elif rule_id == "S05":
        # Rollback at least 2 lines
        count = len(re.findall(r'(回滚|Rollback)', content))
        return count >= 2
    elif rule_id == "S06":
        # Numbered/bullet list: at least 3 items
        count = len(re.findall(r'^[ \t]*[-*+1-9][.)]', content, re.MULTILINE))
        return count >= 3
    elif rule_id == "S07":
        # File size >= 500 bytes
        return _file_size(file_path) >= 500
    return False


# ============================================================================
# D1: Process Integrity (20%)
# ============================================================================

def _score_process_integrity(state, feature_dir):
    """
    Part A (0-50): artifact presence — do files exist with sufficient size?
    Part B (0-50): preset rule hit rate — do files contain required keywords?

    Returns int 0-100 or None.
    """
    current_state = state.get("currentState", "")
    current_sn = _parse_state_num(current_state)
    if current_sn < 0:
        return None

    applicable_gates = _get_applicable_gates(state)

    # --- Part A: Artifact Presence (0-50) ---
    if len(applicable_gates) == 0:
        artifact_score = 50  # No gates applicable = no missing artifacts
    else:
        # S9 + any failed gate (not skipped) → artifact_score = 0
        if current_sn >= 9:
            for gate in applicable_gates:
                if gate.get("status") == "failed":
                    artifact_score = 0
                    break
            else:
                artifact_score = _calc_artifact_score(applicable_gates, feature_dir)
        else:
            artifact_score = _calc_artifact_score(applicable_gates, feature_dir)

    # --- Part B: Preset Rule Hit Rate (0-50) ---
    applicable_rule_count = 0
    hit_count = 0

    for rule_gate_id, artifact_file, candidates in PRESET_RULES:
        # Check if this gate is applicable
        threshold = GATE_STATE_THRESHOLD.get(rule_gate_id, 999)
        if current_sn < threshold:
            continue

        applicable_rule_count += 1

        if artifact_file == "reviews/":
            if _check_preset_rule_reviews(feature_dir, candidates):
                hit_count += 1
        else:
            if _check_preset_rule(feature_dir, artifact_file, candidates):
                hit_count += 1

    if applicable_rule_count == 0:
        preset_rule_score = 50
    else:
        rule_hit_rate = hit_count / applicable_rule_count
        preset_rule_score = round(rule_hit_rate * 50)

    return artifact_score + preset_rule_score


def _calc_artifact_score(applicable_gates, feature_dir):
    """Calculate Part A artifact presence score."""
    ok_count = 0
    for gate in applicable_gates:
        artifacts = gate.get("artifacts", [])
        if not artifacts:
            continue
        gate_ok = True
        for art_path in artifacts:
            full_path = os.path.join(feature_dir, art_path)
            basename = os.path.basename(art_path)
            min_size = ARTIFACT_MIN_SIZE.get(basename, 100)

            if basename and basename != art_path:
                # Regular file
                if not os.path.isfile(full_path) or _file_size(full_path) < min_size:
                    gate_ok = False
                    break
            elif "reviews/" in art_path:
                # Gate 5: reviews/ directory — at least 1 .md >= 200 bytes
                reviews_dir = os.path.join(feature_dir, "reviews")
                if not os.path.isdir(reviews_dir):
                    gate_ok = False
                    break
                md_files = glob_fn(os.path.join(reviews_dir, "*.md"))
                if not any(_file_size(f) >= 200 for f in md_files):
                    gate_ok = False
                    break
            else:
                if not os.path.isfile(full_path) or _file_size(full_path) < min_size:
                    gate_ok = False
                    break

        if gate_ok:
            ok_count += 1

    return round(ok_count / len(applicable_gates) * 50)


# ============================================================================
# D2: Artifact Quality (18%)
# ============================================================================

def _score_artifact_quality(state, feature_dir):
    """
    Part A (0-60): structure integrity — do files have core structural elements?
    Part B (0-40): anti-waterfill — are files real or empty shells?

    Returns int 0-100 or None.
    """
    current_sn = _parse_state_num(state.get("currentState", ""))
    if current_sn < 0:
        return None

    applicable_gates = _get_applicable_gates(state)

    # Collect applicable files
    applicable_files = []
    for gate in applicable_gates:
        for art_path in gate.get("artifacts", []):
            basename = os.path.basename(art_path)
            if basename and basename in ARTIFACT_MIN_SIZE:
                applicable_files.append(basename)
    applicable_files = sorted(set(applicable_files))

    # --- Part A: Structure Integrity (0-60) ---
    struct_score = _calc_structure_integrity(feature_dir, applicable_files)

    # --- Part B: Anti-Waterfill (0-40) ---
    anti_water_score, shell_files, mostly_template_files = _calc_anti_waterfill(
        feature_dir, applicable_files
    )

    return struct_score + anti_water_score, {
        "subScores": {
            "structureIntegrity": struct_score,
            "antiWaterFill": anti_water_score,
        },
        "shellFiles": shell_files,
        "mostlyTemplateFiles": mostly_template_files,
    }


def _calc_structure_integrity(feature_dir, applicable_files):
    """Calculate structure integrity score (0-60)."""
    applicable_rules = []
    for rule_id, file_basename in STRUCTURE_RULES_MATRIX:
        if file_basename in applicable_files:
            applicable_rules.append((rule_id, file_basename))

    if not applicable_rules:
        return 0

    hit_count = 0
    for rule_id, file_basename in applicable_rules:
        full_path = os.path.join(feature_dir, file_basename)
        if _check_structure_rule(rule_id, full_path):
            hit_count += 1

    return round(hit_count / len(applicable_rules) * 60)


def _calc_anti_waterfill(feature_dir, applicable_files):
    """Calculate anti-waterfill score (0-40). Returns (score, shell_list, mostly_list)."""
    shell_files = []
    mostly_template_files = []
    total_score = 0

    for basename in applicable_files:
        full_path = os.path.join(feature_dir, basename)
        if not os.path.isfile(full_path):
            continue

        max_score = ANTI_WATER_MAX_SCORES.get(basename, 4)
        status = _assess_waterfill(full_path, basename)

        if status == "EMPTY_SHELL":
            shell_files.append(basename)
        elif status == "MOSTLY_TEMPLATE":
            mostly_template_files.append(basename)
            total_score += round(max_score * 0.4)
        elif status == "WATER_PADDING":
            shell_files.append(basename)
        else:  # NORMAL
            total_score += max_score

    return total_score, shell_files, mostly_template_files


def _assess_waterfill(file_path, basename):
    """
    Assess a file for waterfill using 4 signals:
    1. shell_ratio (placeholder markers)
    2. template_retention (fingerprint matching)
    3. fill_rate (user content ratio)
    4. edge case (size just over minimum with trailing repetition)
    """
    content = _read_file(file_path)
    if content is None:
        return "EMPTY_SHELL"

    lines = content.split("\n")
    non_empty_lines = [L for L in lines if L.strip()]

    if not non_empty_lines:
        return "EMPTY_SHELL"

    # Signal 1: shell_ratio
    placeholder_count = 0
    for line in non_empty_lines:
        for marker in PLACEHOLDER_MARKERS:
            if marker in line:
                placeholder_count += 1
                break
    shell_ratio = placeholder_count / len(non_empty_lines)

    # Signal 2: template_retention (fingerprint)
    fingerprints = TEMPLATE_FINGERPRINTS.get(basename, [])
    if fingerprints:
        fp_hits = 0
        for fp in fingerprints:
            if fp in content:
                fp_hits += 1
        template_retention = fp_hits / len(fingerprints)
    else:
        template_retention = None

    # Signal 3: fill_rate
    # Format-only lines: ---, pure table lines, empty
    format_patterns = [
        r'^[-]{3,}$',       # --- separator
        r'^\|[\s|:-]*\|$',  # pure table border line
        r'^<!--.*-->$',     # HTML comment
    ]
    user_lines = 0
    for line in non_empty_lines:
        is_format = False
        for pat in format_patterns:
            if re.match(pat, line.strip()):
                is_format = True
                break
        if not is_format:
            # Also exclude fingerprint lines
            is_fp = False
            for fp in fingerprints:
                if fp in line and len(line.strip()) <= len(fp) + 5:
                    is_fp = True
                    break
            if not is_fp:
                user_lines += 1

    fill_rate = user_lines / len(non_empty_lines) if non_empty_lines else 0

    # Signal 4: edge case — size just at threshold with trailing repetition
    actual_size = _file_size(file_path)
    min_size = ARTIFACT_MIN_SIZE.get(basename, 100)
    is_edge = actual_size >= min_size and actual_size <= min_size * 1.1

    if is_edge and actual_size > 20:
        # Check last 10% for repeated chars
        tail_start = max(0, actual_size - max(20, actual_size // 10))
        try:
            with open(file_path, "rb") as f:
                f.seek(tail_start)
                tail = f.read().decode("utf-8", errors="replace")
            # Check for repeated char patterns like "xxxxx" or "aaaaa"
            if re.search(r'(.)\1{4,}', tail):
                return "WATER_PADDING"
        except OSError:
            pass

    # Comprehensive judgment
    # Signal 1 threshold
    if shell_ratio > 0.3:
        return "EMPTY_SHELL"

    # Signal 2 threshold (if available)
    if template_retention is not None and template_retention > 0.85:
        if fill_rate < 0.3:
            return "EMPTY_SHELL"

    if template_retention is not None and template_retention > 0.70:
        if fill_rate < 0.5:
            return "MOSTLY_TEMPLATE"

    # Signal 3 threshold
    if fill_rate < 0.3:
        return "EMPTY_SHELL"
    if fill_rate < 0.5:
        if shell_ratio > 0.1:
            return "MOSTLY_TEMPLATE"

    # Signal 1 fallback
    if shell_ratio > 0.1:
        return "MOSTLY_TEMPLATE"

    return "NORMAL"


# ============================================================================
# D3: Code Correctness (18%)
# ============================================================================

def _score_code_correctness(state, feature_dir):
    """
    Part A (0-50): build correctness
    Part B (0-50): unit test pass rate

    Returns int 0-100, or None if no code data available.
    """
    current_sn = _parse_state_num(state.get("currentState", ""))
    # D3 is only meaningful from S6 onwards (implementation complete)
    if current_sn < 6:
        return None, {"reason": "功能未推进到 S6"}

    verification_path = os.path.join(feature_dir, "05-verification-log.md")
    build_log_path = os.path.join(feature_dir, "build-output.log")
    test_log_path = os.path.join(feature_dir, "test-output.log")

    verif_content = _read_file(verification_path)

    # Check for N/A declaration
    if verif_content and re.search(
        r'(N/A|不涉及代码|no code change|not applicable)',
        verif_content, re.IGNORECASE
    ):
        return 100, {"dataSource": "verification-log.md (N/A declaration)", "subScores": {"buildPass": 50, "unitTestPassRate": 50}}

    # --- Part A: Build Correctness (0-50) ---
    build_score = _calc_build_score(feature_dir, verif_content, build_log_path)

    # --- Part B: Unit Test Pass Rate (0-50) ---
    test_score, test_data_source = _calc_test_score(feature_dir, verif_content, test_log_path)

    # Combine
    sub_scores = {
        "buildPass": build_score if build_score is not None else None,
        "unitTestPassRate": test_score if test_score is not None else None,
    }
    data_source = test_data_source or "verification-log.md"

    if build_score is None and test_score is None:
        return None, {"reason": "无编译或测试数据", "dataSource": None}

    if build_score is not None and test_score is not None:
        return build_score + test_score, {"subScores": sub_scores, "dataSource": data_source}

    if build_score is not None and test_score is None:
        total = min(80, build_score * 2)
        return total, {"subScores": sub_scores, "dataSource": data_source}

    if build_score is None and test_score is not None:
        total = min(80, test_score * 2)
        return total, {"subScores": sub_scores, "dataSource": data_source}

    return None, {"reason": "不可达", "dataSource": None}


def _calc_build_score(feature_dir, verif_content, build_log_path):
    """Calculate build pass score (0-50)."""
    # Priority 1: build-output.log
    if os.path.isfile(build_log_path):
        log_content = _read_file(build_log_path)
        if log_content:
            # EXIT_CODE=<n>
            m = re.search(r'EXIT_CODE[=:]\s*(\d+)', log_content)
            if m:
                return 50 if int(m.group(1)) == 0 else 0
            if re.search(r'BUILD\s+SUCCESS', log_content, re.IGNORECASE):
                return 50
            if re.search(r'BUILD\s+FAILURE', log_content, re.IGNORECASE):
                return 0

    # Priority 2-3: verification-log.md
    if verif_content:
        if re.search(r'编译结果[：:]\s*PASS', verif_content):
            return 50
        if re.search(r'编译结果[：:]\s*FAIL', verif_content):
            return 0
        if re.search(r'Build[：:]\s*SUCCESS', verif_content):
            return 50
        if re.search(r'Build[：:]\s*FAILURE', verif_content):
            return 0

    # Priority 5: unknown — check for mention
    if verif_content and re.search(r'(编译|build|compile|Build)', verif_content, re.IGNORECASE):
        return 25

    return None


def _calc_test_score(feature_dir, verif_content, test_log_path):
    """Calculate unit test pass rate score (0-50). Returns (score, data_source)."""
    # Priority 1: test-output.log
    if os.path.isfile(test_log_path):
        log_content = _read_file(test_log_path)
        if log_content:
            m = re.search(r'Tests run[：:]\s*(\d+).*?Failures[：:]\s*(\d+)', log_content, re.IGNORECASE)
            if m:
                total = int(m.group(1))
                failures = int(m.group(2))
                passed = total - failures
                if total > 0:
                    return round(passed / total * 50), "test-output.log"
            # PASS/FAIL lines
            passes = len(re.findall(r'^PASS\s+', log_content, re.MULTILINE | re.IGNORECASE))
            fails = len(re.findall(r'^FAIL\s+', log_content, re.MULTILINE | re.IGNORECASE))
            total = passes + fails
            if total > 0:
                return round(passes / total * 50), "test-output.log"

    # Priority 2-3: verification-log.md
    if verif_content:
        # 单元测试: 通过 X/Y
        m = re.search(r'单元测试[：:]\s*通过\s*(\d+)\s*/\s*(\d+)', verif_content)
        if m:
            passed = int(m.group(1))
            total = int(m.group(2))
            if total > 0:
                return round(passed / total * 50), "verification-log.md"

        # Tests: X passed, Y failed, Z total
        m = re.search(r'Tests[：:]\s*(\d+)\s*passed.*?(\d+)\s*failed.*?(\d+)\s*total', verif_content, re.IGNORECASE)
        if m:
            passed = int(m.group(1))
            total = int(m.group(3))
            if total > 0:
                return round(passed / total * 50), "verification-log.md"

        # Unit Test Exit Code: 0
        if re.search(r'Unit\s+Test\s+Exit\s+Code[：:]\s*0', verif_content, re.IGNORECASE):
            return 50, "verification-log.md"

    # Priority 5: unknown — check for mention
    if verif_content and re.search(
        r'(单元测试|unit test|Unit Test|测试通过|Tests.*passed)',
        verif_content, re.IGNORECASE
    ):
        return 25, "verification-log.md"

    return None, None


# ============================================================================
# D4: Efficiency (8%)
# ============================================================================

def _score_efficiency(state):
    """
    Part A (0-50): time efficiency
    Part B (0-50): token efficiency
    Part C: anti-circling penalty (0-30, optional)

    Returns int 0-100 or None.
    """
    state_history = state.get("stateHistory", [])
    current_state = state.get("currentState", "")
    current_sn = _parse_state_num(current_state)
    completed_at = state.get("completedAt")
    updated_at = state.get("updatedAt")
    feedback_loop = state.get("feedbackLoop") or {}
    metadata = state.get("metadata") or {}

    # --- Part A: Time Efficiency (0-50) ---
    time_score, elapsed_hours = _calc_time_efficiency(
        state_history, current_state, current_sn,
        completed_at, updated_at, feedback_loop
    )

    # --- Part B: Token Efficiency (0-50) ---
    token_score, total_tokens = _calc_token_efficiency(metadata)

    # --- Part C: Anti-circling (0-30 penalty, optional) ---
    circling_penalty = 0  # Tool call logs not available → skip

    # Combine
    if token_score is None:
        efficiency = min(100, time_score * 2 - circling_penalty)
    else:
        efficiency = max(0, time_score + token_score - circling_penalty)

    return efficiency, {
        "subScores": {
            "timeEfficiency": time_score,
            "tokenEfficiency": token_score,
        },
        "elapsedHours": elapsed_hours,
        "totalTokens": total_tokens,
        "complexity": metadata.get("complexity", "medium"),
    }


def _calc_time_efficiency(state_history, current_state, current_sn,
                          completed_at, updated_at, feedback_loop):
    """Calculate time efficiency score (0-50)."""
    if not state_history:
        return 25, None

    # Get start and end timestamps
    t_start = _iso_to_dt(state_history[0].get("timestamp"))
    if t_start is None:
        return 25, None

    # Determine end time
    t_end = None
    if completed_at:
        t_end = _iso_to_dt(completed_at)
    if t_end is None and updated_at:
        t_end = _iso_to_dt(updated_at)
    if t_end is None:
        t_end = _iso_to_dt(state_history[-1].get("timestamp"))

    if t_end is None:
        return 25, None

    elapsed_seconds = (t_end - t_start).total_seconds()
    elapsed_hours = round(elapsed_seconds / 3600.0, 1)

    if elapsed_hours <= 0:
        return 50, elapsed_hours

    # Stage-aware ideal hours
    if current_sn <= 2:
        stage_ideal = 2
    elif current_sn <= 5:
        stage_ideal = 6
    elif current_sn <= 7:
        stage_ideal = 8
    else:
        stage_ideal = 9

    efficiency_ratio = stage_ideal / elapsed_hours
    time_score = round(min(efficiency_ratio, 2.0) * 25)

    # Stall penalty
    stalled_since = feedback_loop.get("stalledSince")
    if stalled_since:
        stalled_dt = _iso_to_dt(stalled_since)
        if stalled_dt:
            now = datetime.now(timezone.utc)
            stall_hours = _hours_between(stalled_dt, now)
            if stall_hours is not None:
                if stall_hours > 72:
                    time_score = max(0, time_score - 25)
                elif stall_hours > 48:
                    time_score = max(0, time_score - 15)
                elif stall_hours > 24:
                    time_score = max(0, time_score - 5)

    return time_score, elapsed_hours


def _calc_token_efficiency(metadata):
    """Calculate token efficiency score (0-50). Returns (score, total_tokens)."""
    token_usage = metadata.get("tokenUsage")
    complexity = metadata.get("complexity", "medium")

    total_tokens = None

    if token_usage:
        input_tokens = token_usage.get("totalInputTokens", 0)
        output_tokens = token_usage.get("totalOutputTokens", 0)
        total_tokens = input_tokens + output_tokens
    else:
        # Can't estimate without file access — return null
        return None, None

    if total_tokens <= 0:
        return 50, 0

    baseline = TOKEN_BASELINE.get(complexity, 150000)
    token_ratio = baseline / max(total_tokens, 1)
    token_score = round(min(token_ratio, 3.0) / 3.0 * 50)

    return token_score, total_tokens


# ============================================================================
# D5: Security Compliance (16%) + One-Vote Veto
# ============================================================================

def _score_security_compliance(state, feature_dir):
    """
    Check harness rule violations across L0-L3 levels.
    Each violation deducts points from a starting score of 100.

    Returns (score: int, violations: list, veto_info: dict).
    """
    violations = []
    veto_triggered = False
    veto_type = None

    gates = state.get("gates", [])
    mode = state.get("mode", "dual-agent")
    current_state = state.get("currentState", "")
    current_sn = _parse_state_num(current_state)
    state_history = state.get("stateHistory", [])
    fallback_events = state.get("fallbackEvents") or []
    human_decisions = state.get("humanDecisions") or []
    orchestrator = state.get("orchestrator", "")
    feedback_loop = state.get("feedbackLoop") or {}
    branch_tasks = state.get("branchTasks") or []

    score = 100

    # ================================================================
    # L0: Fatal violations (trigger veto)
    # ================================================================

    # L0-1: Gate Bypass — detect illegal state transitions
    bypassed_gates = _detect_gate_bypass(state_history)
    if bypassed_gates:
        penalty = 50 * len(bypassed_gates)
        score -= penalty
        violations.append({
            "rule": "L0-1", "level": "L0_FATAL", "penalty": penalty,
            "detail": f"门禁跳跃：检测到非法状态转换，跳过门禁: {bypassed_gates}",
        })
        veto_triggered = True
        veto_type = "GATE_BYPASS"

    # L0-2: Mode Fraud
    mode_fraud = _detect_mode_fraud(mode, state, feature_dir)
    if mode_fraud:
        score -= 60
        violations.append({
            "rule": "L0-2", "level": "L0_FATAL", "penalty": 60,
            "detail": mode_fraud,
        })
        veto_triggered = True
        veto_type = "MODE_FRAUD"

    # L0-3: Review Fabrication
    review_fab = _detect_review_fabrication(state, feature_dir)
    if review_fab:
        fab_penalty = min(100, 60 * len(review_fab))
        score -= fab_penalty
        violations.append({
            "rule": "L0-3", "level": "L0_FATAL", "penalty": fab_penalty,
            "detail": f"审查伪造：{'; '.join(review_fab)}",
        })
        veto_triggered = True
        veto_type = "REVIEW_FABRICATION"

    # L0-4: State Tampering
    tampering = _detect_state_tampering(gates, feature_dir)
    if tampering:
        score -= 80
        violations.append({
            "rule": "L0-4", "level": "L0_FATAL", "penalty": 80,
            "detail": tampering,
        })
        veto_triggered = True
        veto_type = "STATE_TAMPERING"

    # ================================================================
    # L1: Serious violations
    # ================================================================

    l1_count = 0

    # L1-1: Unauthorized Modification (simplified — checks workflow files)
    unauthorized = _detect_unauthorized_mods(state, feature_dir)
    for uf in unauthorized:
        score -= uf["penalty"]
        violations.append({
            "rule": "L1-1", "level": "L1_SERIOUS", "penalty": uf["penalty"],
            "detail": f"越权修改：{uf['file']}",
        })
        l1_count += 1

    # L1-2: Human Checkpoint Bypass
    hcb = _detect_human_checkpoint_bypass(state, gates, human_decisions, feedback_loop)
    for h in hcb:
        score -= h["penalty"]
        violations.append({
            "rule": "L1-2", "level": "L1_SERIOUS", "penalty": h["penalty"],
            "detail": h["detail"],
        })
        l1_count += 1

    # L1-3: Scope Drift (simplified — checked via implementation plan)
    # Skipped: requires git diff analysis which is not deterministic without git repo

    # ================================================================
    # L2: Medium violations
    # ================================================================

    # L2-1: Role Confusion
    if _detect_role_confusion(state, orchestrator, feature_dir):
        score -= 20
        violations.append({
            "rule": "L2-1", "level": "L2_MEDIUM", "penalty": 20,
            "detail": f"角色混淆：orchestrator={orchestrator} 与制品作者不匹配",
        })

    # L2-2: Handoff file missing/shell
    handoff_issues = _detect_handoff_issues(state_history, mode, feature_dir)
    for hi in handoff_issues:
        score -= hi["penalty"]
        violations.append({
            "rule": "L2-2", "level": "L2_MEDIUM", "penalty": hi["penalty"],
            "detail": hi["detail"],
        })

    # L2-3: Branch Merge Anomaly
    branch_anomaly = _detect_branch_anomaly(branch_tasks, current_sn)
    if branch_anomaly:
        score -= branch_anomaly["penalty"]
        violations.append({
            "rule": "L2-3", "level": "L2_MEDIUM", "penalty": branch_anomaly["penalty"],
            "detail": branch_anomaly["detail"],
        })

    # ================================================================
    # L3: Minor violations
    # ================================================================

    # L3-2: Experience Pipeline Incomplete (only when >= S8)
    if current_sn >= 8:
        exp_incomplete = _detect_experience_pipeline_incomplete(feature_dir)
        if exp_incomplete:
            score -= 5
            violations.append({
                "rule": "L3-2", "level": "L3_MINOR", "penalty": 5,
                "detail": exp_incomplete,
            })

    score = max(0, score)

    # ================================================================
    # Cumulative L1 veto
    # ================================================================
    if l1_count >= 3:
        veto_triggered = True
        veto_type = "CUMULATIVE_L1"

    # ================================================================
    # D1+D5 double breach (checked by caller)
    # ================================================================

    veto_info = {
        "triggered": veto_triggered,
        "vetoType": veto_type,
        "totalOverride": 0 if (veto_type == "STATE_TAMPERING") else (
            39 if veto_triggered else None
        ),
    }

    return score, violations, veto_info


def _detect_gate_bypass(state_history):
    """Detect illegal state transitions. Returns list of skipped gate IDs."""
    if not state_history:
        return []
    bypassed = []
    for i in range(1, len(state_history)):
        prev_to = state_history[i - 1].get("to", "")
        curr_from = state_history[i].get("from", "")
        curr_to = state_history[i].get("to", "")

        # Check the transition pair
        transition = (prev_to, curr_to)
        if transition not in LEGAL_TRANSITIONS:
            # Determine which gates were skipped
            prev_sn = _parse_state_num(prev_to)
            curr_sn = _parse_state_num(curr_to)
            if curr_sn > prev_sn >= 0:
                for sn in range(prev_sn + 1, curr_sn):
                    gate_id = _sn_to_gate(sn)
                    if gate_id:
                        bypassed.append(gate_id)
    return list(set(bypassed))


def _sn_to_gate(sn):
    """Map S-state number to gate ID."""
    for gate_id, threshold in GATE_STATE_THRESHOLD.items():
        if threshold == sn:
            return gate_id
    return None


def _detect_mode_fraud(mode, state, feature_dir):
    """Detect mode fraud: single-agent mode claiming dual-agent review."""
    if mode != "single-agent":
        return None

    reviews_dir = os.path.join(feature_dir, "reviews")
    if not os.path.isdir(reviews_dir):
        return None

    md_files = glob_fn(os.path.join(reviews_dir, "*.md"))
    if len(md_files) < 2:
        return None

    # single-agent mode should NOT have 2 review files
    has_codex = any("codex" in os.path.basename(f).lower() for f in md_files)
    has_claude = any("claude" in os.path.basename(f).lower() for f in md_files)

    if has_codex and has_claude:
        # Check content for dual-agent claims
        for f in md_files:
            content = _read_file(f, max_lines=100)
            if content and ("dual-agent" in content or "双Agent" in content
                           or "Codex审查" in content or "双方" in content):
                return "模式欺诈：single-agent 模式下声称双Agent审查完成"
        return "模式欺诈：single-agent 模式下存在 2 份审查报告"

    return None


def _detect_review_fabrication(state, feature_dir):
    """Detect review fabrication signals. Returns list of descriptions."""
    issues = []
    reviews_dir = os.path.join(feature_dir, "reviews")
    if not os.path.isdir(reviews_dir):
        return issues

    md_files = glob_fn(os.path.join(reviews_dir, "*.md"))
    if not md_files:
        return issues

    for f in md_files:
        content = _read_file(f)
        if content is None:
            continue
        # Check for P0 findings with too-short descriptions
        # (P0 should have substantial descriptions)
        if re.search(r'\bP0\b', content):
            # Rough check: P0 sections with very short content
            p0_sections = re.findall(r'P0[^P\n]{1,100}', content)
            for sec in p0_sections:
                if len(sec.strip()) < 50:
                    issues.append(f"{os.path.basename(f)}: P0 发现描述过短 (<50字符)")
                    break

    return issues


def _detect_state_tampering(gates, feature_dir):
    """Detect state tampering: passed gates with missing artifacts.

    Only triggers on clear contradictions between gate status and filesystem reality.
    resolvedAt being null is NOT tampering — it's an optional metadata field.
    Tampering means: gate claims 'passed' but the required artifact file is
    missing or empty on disk.
    """
    tampering_evidence = []
    for gate in gates:
        if gate.get("status") != "passed":
            continue
        gate_id = gate.get("gateId", "?")
        artifacts = gate.get("artifacts", [])
        missing_artifacts = []

        for art in artifacts:
            full_path = os.path.join(feature_dir, art)
            basename = os.path.basename(art)
            min_size = ARTIFACT_MIN_SIZE.get(basename, 100)

            # Check individual file artifacts
            if basename and basename != art:
                if not os.path.isfile(full_path):
                    missing_artifacts.append(f"{art} (不存在)")
                elif _file_size(full_path) < min_size:
                    missing_artifacts.append(f"{art} (<{min_size}B)")
            elif basename and basename == art:
                # Artifact is just a filename — resolve in feature_dir
                candidate = os.path.join(feature_dir, basename)
                if not os.path.isfile(candidate):
                    missing_artifacts.append(f"{art} (不存在)")
                elif _file_size(candidate) < min_size:
                    missing_artifacts.append(f"{art} (<{min_size}B)")
            elif "reviews/" in art:
                # Directory check
                reviews_dir = os.path.join(feature_dir, "reviews")
                if not os.path.isdir(reviews_dir):
                    missing_artifacts.append("reviews/ (目录不存在)")
                else:
                    md_files = glob_fn(os.path.join(reviews_dir, "*.md"))
                    if not any(_file_size(f) >= 200 for f in md_files):
                        missing_artifacts.append("reviews/ (无有效审查文件)")

        if missing_artifacts:
            tampering_evidence.append(
                f"{gate_id} passed 但产物缺失: {'; '.join(missing_artifacts)}"
            )

    if tampering_evidence:
        return " | ".join(tampering_evidence)
    return None


def _detect_unauthorized_mods(state, feature_dir):
    """Detect unauthorized workflow file modifications. Simplified heuristic."""
    issues = []
    # Check if essential files were modified outside their gates
    gates = state.get("gates", [])
    current_sn = _parse_state_num(state.get("currentState", ""))

    for gate in gates:
        gate_id = gate.get("gateId", "")
        threshold = GATE_STATE_THRESHOLD.get(gate_id, 999)
        # If not reached this gate, its artifacts should not exist
        if current_sn >= 0 and current_sn < threshold:
            for art in gate.get("artifacts", []):
                full_path = os.path.join(feature_dir, art)
                basename = os.path.basename(art)
                if basename and basename != art and os.path.isfile(full_path):
                    issues.append({
                        "file": art,
                        "penalty": 20,
                    })
    return issues


def _detect_human_checkpoint_bypass(state, gates, human_decisions, feedback_loop):
    """Detect human checkpoint bypass violations."""
    issues = []
    mode = state.get("mode", "")

    # 1. New feature without gate-1 human decision
    # Heuristic: if gate-1 is passed/skipped but no human decision for gate-1
    gate1 = next((g for g in gates if g.get("gateId") == "gate-1"), None)
    if gate1 and gate1.get("status") in ("passed", "skipped"):
        has_human = any(
            (d.get("madeBy") == "human" or d.get("approvedBy")) and d.get("gateId") == "gate-1"
            for d in human_decisions
        )
        if not has_human:
            # Only flag if not explicitly skipped
            if gate1.get("status") != "skipped":
                issues.append({
                    "penalty": 35,
                    "detail": "人类Checkpoint绕过：Gate 1 无人类决策记录",
                })

    # 2. Retry exhausted without escalation
    retry_count = feedback_loop.get("retryCount", 0)
    max_retries = feedback_loop.get("maxRetries", 3)
    if retry_count >= max_retries:
        has_escalation = any(
            d.get("madeBy") == "human" and "升级" in d.get("summary", "")
            for d in human_decisions
        )
        if not has_escalation:
            issues.append({
                "penalty": 25,
                "detail": f"重试耗尽（{retry_count}/{max_retries}）但无人类升级记录",
            })

    return issues


def _detect_role_confusion(state, orchestrator, feature_dir):
    """Detect role confusion: orchestrator doesn't match artifact creators."""
    # Check grill-me report authorship vs orchestrator
    grill_path = os.path.join(feature_dir, "02-grill-me-report.md")
    content = _read_file(grill_path, max_lines=30)
    if content is None:
        return False

    if orchestrator == "claude":
        # Orchestrator is Claude, but was grill-me done by Claude? (should be Codex)
        if "Reviewer: claude" in content or "审查者: claude" in content:
            return True
    elif orchestrator == "codex":
        if "Reviewer: codex" in content or "审查者: codex" in content:
            return True

    return False


def _detect_handoff_issues(state_history, mode, feature_dir):
    """Detect handoff file issues in dual-agent mode."""
    issues = []
    if mode != "dual-agent":
        return issues

    handoffs_dir = os.path.join(feature_dir, "..", "..", "..", "handoffs")
    # Resolve relative to feature dir: features/<id>/ -> workflow/
    script_dir = Path(__file__).resolve().parent   # workflow/eval/
    workflow_dir = script_dir.parent                # workflow/
    handoffs_dir = workflow_dir / "handoffs"

    for transition in state_history:
        if transition.get("trigger") != "agent-handoff":
            continue
        handoff_file = transition.get("handoffFile")
        actor = transition.get("actor", "")

        if handoff_file:
            # Check the file exists
            full_path = workflow_dir / handoff_file if not os.path.isabs(handoff_file) else Path(handoff_file)
            if not full_path.is_file():
                issues.append({
                    "penalty": 20,
                    "detail": f"交接文件缺失: {handoff_file}",
                })
            elif _file_size(str(full_path)) < 100:
                issues.append({
                    "penalty": 15,
                    "detail": f"交接文件空壳: {handoff_file}",
                })
        else:
            # No handoff file recorded
            issues.append({
                "penalty": 10,
                "detail": f"agent-handoff 转换缺失 handoffFile 字段 (actor={actor})",
            })

    return issues


def _detect_branch_anomaly(branch_tasks, current_sn):
    """Detect branch merge anomalies."""
    if not branch_tasks:
        return None

    # If >= S8 but some branches not completed
    if current_sn >= 8:
        incomplete = [b for b in branch_tasks if b.get("status") not in ("completed",)]
        if incomplete:
            ids = [b.get("branchId", "?") for b in incomplete]
            return {
                "penalty": 15,
                "detail": f"分支合并异常：S8+ 但分支未完成: {ids}",
            }

    # If any branch is paused but trunk is >= S8
    paused = [b for b in branch_tasks if b.get("status") == "paused"]
    if paused and current_sn >= 8:
        ids = [b.get("branchId", "?") for b in paused]
        return {
            "penalty": 20,
            "detail": f"分支合并异常：暂停的分支 {ids} 但主干已达 S8+",
        }

    return None


def _detect_experience_pipeline_incomplete(feature_dir):
    """Check if experience pipeline is incomplete for S8+ features."""
    script_dir = Path(__file__).resolve().parent
    workflow_dir = script_dir.parent
    experience_dir = workflow_dir / "experience"

    lessons_dir = experience_dir / "lessons"
    patterns_dir = experience_dir / "patterns"
    instincts_dir = experience_dir / "instincts"

    lessons_new = any(
        f.is_file() for f in lessons_dir.iterdir()
    ) if lessons_dir.is_dir() else False
    patterns_new = any(
        f.is_file() for f in patterns_dir.iterdir()
    ) if patterns_dir.is_dir() else False
    instincts_new = any(
        f.is_file() for f in instincts_dir.iterdir()
    ) if instincts_dir.is_dir() else False

    retro_path = os.path.join(feature_dir, "07-task-retro.md")
    retro_content = _read_file(retro_path)
    has_declaration = False
    if retro_content:
        has_declaration = "无直接相关经验" in retro_content or "no direct experience" in retro_content.lower()

    if not (lessons_new or patterns_new or instincts_new) and not has_declaration:
        return "经验管道闭合不完整：S8+ 但 experience/ 无新内容且 retro 未声明"

    return None


# ============================================================================
# D6: Iteration Capability (12%)
# ============================================================================

def _score_iteration_capability(state):
    """
    Part A (0-40): fix success rate
    Part B (0-50): compile/test fix chains
    Part C (0-10): diagnosis quality

    Returns int 0-100.
    """
    feedback_loop = state.get("feedbackLoop") or {}
    retry_history = feedback_loop.get("retryHistory", [])
    last_failure = feedback_loop.get("lastFailure")

    total = len(retry_history)

    # Never failed → full marks
    if total == 0:
        if last_failure is None:
            return 100, {
                "subScores": {
                    "fixSuccessRate": 40,
                    "compileChains": 0,
                    "testChains": 0,
                    "diagnosisQuality": 0,
                },
                "compileFixChains": 0,
                "testFixChains": 0,
                "retryTotal": 0,
                "retrySelfFixed": 0,
            }
        else:
            # Failed but never retried
            return 0, {
                "subScores": {
                    "fixSuccessRate": 0,
                    "compileChains": 0,
                    "testChains": 0,
                    "diagnosisQuality": 0,
                },
                "compileFixChains": 0,
                "testFixChains": 0,
                "retryTotal": 0,
                "retrySelfFixed": 0,
            }

    # --- Part A: Fix Success Rate (0-40) ---
    passed = sum(1 for r in retry_history if r.get("result") == "passed")
    escalated = sum(1 for r in retry_history if r.get("result") == "escalated")
    self_fix_rate = max(0, passed - escalated) / total if total > 0 else 0
    fix_score = round(self_fix_rate * 40)

    # --- Part B: Fix Chains (0-50) ---
    compile_chains, test_chains = _detect_fix_chains(retry_history)
    chain_score = min(compile_chains, 3) * 15 + min(test_chains, 2) * 5

    # --- Part C: Diagnosis Quality (0-10) ---
    diagnosis_score = _calc_diagnosis_quality(retry_history)

    # Part B+C cap at 50
    part_bc = min(50, chain_score + diagnosis_score)

    total_score = fix_score + part_bc

    return total_score, {
        "subScores": {
            "fixSuccessRate": fix_score,
            "compileChains": chain_score if compile_chains > 0 or test_chains > 0 else 0,
            "testChains": 0,
            "diagnosisQuality": diagnosis_score,
        },
        "compileFixChains": compile_chains,
        "testFixChains": test_chains,
        "retryTotal": total,
        "retrySelfFixed": max(0, passed - escalated),
    }


def _detect_fix_chains(retry_history):
    """
    Detect compile-fix-pass and test-fix-pass chains using sliding window.

    Compile chain definition:
      entry[i].failureReason contains compile/build/type-error/syntax-error keywords
      AND entry[i].result == "failed-again"
      entry[i+1].failureReason contains same keywords
      AND entry[i+1].result == "passed"

    Relaxed definition (when failureReason missing):
      entry[i].failedGate == "gate-6" AND result == "failed-again"
      entry[i+1].failedGate == "gate-6" AND result == "passed"
    """
    COMPILE_KEYWORDS = ["编译", "compile", "build", "type error", "syntax error"]
    TEST_KEYWORDS = ["test", "测试", "assert", "expect", "fail"]

    def _has_compile_keyword(reason):
        if not reason:
            return False
        reason_lower = reason.lower()
        return any(kw in reason_lower for kw in COMPILE_KEYWORDS)

    def _has_test_keyword(reason):
        if not reason:
            return False
        reason_lower = reason.lower()
        return any(kw in reason_lower for kw in TEST_KEYWORDS)

    compile_chains = 0
    test_chains = 0
    used_indices = set()  # prevent overlapping chains

    for i in range(len(retry_history) - 1):
        if i in used_indices:
            continue

        entry_i = retry_history[i]
        entry_next = retry_history[i + 1]

        reason_i = entry_i.get("failureReason", "")
        reason_next = entry_next.get("failureReason", "")
        failed_gate_i = entry_i.get("failedGate", "")
        failed_gate_next = entry_next.get("failedGate", "")

        result_i = entry_i.get("result", "")
        result_next = entry_next.get("result", "")

        # Compile chain (strict)
        if result_i == "failed-again" and result_next == "passed":
            compile_i = _has_compile_keyword(reason_i)
            compile_next = _has_compile_keyword(reason_next)

            if compile_i and compile_next:
                compile_chains += 1
                used_indices.add(i)
                used_indices.add(i + 1)
                continue

            # Relaxed: both gate-6
            if (not compile_i and not compile_next
                    and failed_gate_i == "gate-6" and failed_gate_next == "gate-6"):
                compile_chains += 1
                used_indices.add(i)
                used_indices.add(i + 1)
                continue

            # Test chain
            test_i = _has_test_keyword(reason_i)
            test_next = _has_test_keyword(reason_next)

            if test_i and test_next:
                test_chains += 1
                used_indices.add(i)
                used_indices.add(i + 1)

    return compile_chains, test_chains


def _calc_diagnosis_quality(retry_history):
    """Calculate diagnosis quality score (0-10)."""
    total = len(retry_history)
    if total == 0:
        return 0

    action_count = sum(
        1 for r in retry_history
        if r.get("actionTaken") and len(str(r.get("actionTaken", ""))) >= 20
    )
    detailed_count = sum(
        1 for r in retry_history
        if r.get("actionTaken") and len(str(r.get("actionTaken", ""))) >= 50
    )

    has_any = 1 if action_count > 0 else 0
    detailed_ratio = detailed_count / total
    return has_any * 5 + round(min(detailed_ratio, 1.0) * 5)


# ============================================================================
# D7: Interface Acceptance (8%)
# ============================================================================

def _score_interface_acceptance(state, feature_dir):
    """
    Part A (0-60): integration test pass rate
    Part B (0-40): contract checks (C01-C04)

    Returns int 0-100 or None.
    """
    current_sn = _parse_state_num(state.get("currentState", ""))
    if current_sn < 6:
        return None, {"reason": "功能未推进到 S6"}

    verification_path = os.path.join(feature_dir, "05-verification-log.md")
    int_test_log_path = os.path.join(feature_dir, "integration-test-output.log")

    verif_content = _read_file(verification_path)

    # Check N/A declaration
    if verif_content and re.search(
        r'(N/A|不涉及接口|no integration tests)',
        verif_content, re.IGNORECASE
    ):
        return None, {"reason": "功能不涉及接口"}

    metadata = state.get("metadata") or {}
    tier = metadata.get("integrationTestTier", 3)

    # --- Part A: Integration Test Pass Rate (0-60) ---
    int_score = _calc_integration_score(feature_dir, verif_content, int_test_log_path)

    # --- Part B: Contract Checks (0-40) ---
    contract_score = _calc_contract_score(verif_content)

    # Combine
    if int_score is None:
        if contract_score > 0:
            raw = contract_score
        else:
            if verif_content and re.search(
                r'(手动.*验收|manual.*test)',
                verif_content, re.IGNORECASE
            ):
                raw = 40
            else:
                return None, {"reason": "无集成测试数据"}
    else:
        raw = int_score + contract_score

    # Apply tier cap
    if tier == 1:
        final = raw
    elif tier == 2:
        final = min(85, raw)
    else:
        final = min(60, raw)

    return final, {
        "subScores": {
            "integrationPassRate": int_score,
            "contractChecks": contract_score,
        },
        "tier": tier,
    }


def _calc_integration_score(feature_dir, verif_content, int_test_log_path):
    """Calculate integration test pass rate (0-60)."""
    # Priority 1: integration-test-output.log
    if os.path.isfile(int_test_log_path):
        log_content = _read_file(int_test_log_path)
        if log_content:
            m = re.search(r'Tests\s+run[：:]\s*(\d+).*?Failures[：:]\s*(\d+)',
                          log_content, re.IGNORECASE)
            if m:
                total = int(m.group(1))
                failures = int(m.group(2))
                if total > 0:
                    return round((total - failures) / total * 60)

    if not verif_content:
        return None

    # Priority 2: verification-log.md patterns
    # 集成测试: 通过 X/Y
    m = re.search(r'集成测试[：:]\s*通过\s*(\d+)\s*/\s*(\d+)', verif_content)
    if m:
        passed = int(m.group(1))
        total = int(m.group(2))
        if total > 0:
            return round(passed / total * 60)

    # Integration Tests: X passed, Y failed, Z total
    m = re.search(r'Integration\s+Tests[：:]\s*(\d+)\s*passed.*?(\d+)\s*failed.*?(\d+)\s*total',
                  verif_content, re.IGNORECASE)
    if m:
        passed = int(m.group(1))
        total = int(m.group(3))
        if total > 0:
            return round(passed / total * 60)

    # E2E Tests: SUCCESS/FAILURE
    if re.search(r'E2E\s+Tests[：:]\s*SUCCESS', verif_content, re.IGNORECASE):
        return 60

    return None


def _calc_contract_score(verif_content):
    """Calculate contract check score (0-40)."""
    if not verif_content:
        return 0

    score = 0
    # C01: API response format validation
    if re.search(r'(API.*验证|接口.*契约|contract.*valid|schema.*valid|OpenAPI|响应格式)',
                 verif_content, re.IGNORECASE):
        score += 10

    # C02: Error handling paths
    if re.search(r'(错误路径|error path|错误处理|error handling|4xx|5xx|异常)',
                 verif_content, re.IGNORECASE):
        score += 10

    # C03: Data model / migration validation
    if re.search(r'(迁移.*验证|migration.*valid|数据.*一致|schema.*migrat)',
                 verif_content, re.IGNORECASE):
        score += 10

    # C04: Compatibility check
    if re.search(r'(向后兼容|backward.*compat|breaking.*change|兼容|regression)',
                 verif_content, re.IGNORECASE):
        score += 10

    return score


# ============================================================================
# Weighted Total & Grade
# ============================================================================

def _weighted_total(raw_scores, weights):
    """
    Compute weighted total from dimension scores.
    Handles null dimensions by redistributing their weight.

    Returns (total: int or None, dimensions: dict).
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

    if valid_weight_sum == 0.0:
        return None, _build_dimensions_output(raw_scores, weights, {})

    scaling_factor = 1.0 / valid_weight_sum if valid_weight_sum > 0 else 1.0

    total = 0.0
    adjusted = {}
    for dim, (score, weight) in valid.items():
        adj_weight = weight * scaling_factor
        adjusted[dim] = (score, weight, adj_weight, round(score * adj_weight, 1))
        total += score * adj_weight

    total = round(total)
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


# ============================================================================
# Baseline Comparison (reused from v1)
# ============================================================================

def _compare_baseline(total, raw_scores, baseline):
    """Compare feature score against baseline."""
    if baseline is None:
        return None

    current = baseline.get("currentBaseline")
    if current is None:
        return {"status": "no_baseline", "delta": None, "dimensionDeltas": {}}

    baseline_version = baseline.get("version", "unknown")
    baseline_total = current.get("totalScore")
    baseline_dims = current.get("dimensions", {})

    if baseline_total is None:
        return {"baselineVersion": baseline_version, "status": "no_baseline",
                "delta": None, "dimensionDeltas": {}}

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
        "baselineVersion": baseline_version,
        "baselineTotal": baseline_total,
        "delta": delta,
        "status": status,
        "dimensionDeltas": dim_deltas,
    }


# ============================================================================
# Warnings Collection
# ============================================================================

def _collect_warnings(state, raw_scores, extra_info, feature_dir):
    """Collect warnings from the scoring process."""
    warnings = []
    gates = state.get("gates", [])
    current_state = state.get("currentState", "")
    fallback_events = state.get("fallbackEvents")
    state_history = state.get("stateHistory", [])

    # Gates count mismatch
    if len(gates) != 7:
        warnings.append({
            "dimension": "processIntegrity",
            "code": "GATES_COUNT_MISMATCH",
            "message": f"gates[] 长度为 {len(gates)}，期望 7",
            "severity": "P2",
        })

    # Invalid gate statuses
    for g in gates:
        if g.get("status") not in VALID_GATE_STATUSES:
            warnings.append({
                "dimension": "processIntegrity",
                "code": "INVALID_GATE_STATUS",
                "message": f"{g.get('gateId')} 的 status '{g.get('status')}' 非标准枚举值",
                "severity": "P2",
            })

    # Null fallbackEvents
    if fallback_events is None:
        warnings.append({
            "dimension": "securityCompliance",
            "code": "FALLBACK_EVENTS_NULL",
            "message": "fallbackEvents 为 null，假设无降级事件",
            "severity": "P3",
        })

    # Empty stateHistory
    if not state_history:
        warnings.append({
            "dimension": None,
            "code": "STATE_HISTORY_EMPTY",
            "message": "stateHistory 为空，无法验证状态转换轨迹",
            "severity": "P2",
        })

    # D2: empty shells
    if extra_info and "d2_extra" in extra_info:
        d2 = extra_info["d2_extra"]
        for f in d2.get("shellFiles", []):
            warnings.append({
                "dimension": "artifactQuality",
                "code": "EMPTY_SHELL_DETECTED",
                "message": f"{f} 被检测为空壳模板",
                "severity": "P2",
            })

    # D3: verification log missing at S6+
    current_sn = _parse_state_num(current_state)
    if current_sn >= 6:
        verif_path = os.path.join(feature_dir, "05-verification-log.md")
        if not os.path.isfile(verif_path):
            warnings.append({
                "dimension": "codeCorrectness",
                "code": "VERIFICATION_LOG_MISSING",
                "message": "05-verification-log.md 缺失，尽管功能已达到 S6+",
                "severity": "P2",
            })

    # D7: missing ADR/retro at S8+
    if current_sn >= 8:
        for fname, dim, code in [
            ("06-adr.md", "interfaceAcceptance", "ADR_MISSING"),
            ("07-task-retro.md", "interfaceAcceptance", "RETRO_MISSING"),
        ]:
            fp = os.path.join(feature_dir, fname)
            if not os.path.isfile(fp):
                warnings.append({
                    "dimension": dim,
                    "code": code,
                    "message": f"{fname} 不存在，尽管功能已进入 S8+",
                    "severity": "P2",
                })

    return warnings


# ============================================================================
# Raw Inputs Collection
# ============================================================================

def _collect_raw_inputs(state, raw_scores, feature_dir):
    """Collect raw inputs for auditability."""
    gates = state.get("gates", [])
    feedback_loop = state.get("feedbackLoop") or {}
    fallback_events = state.get("fallbackEvents") or []
    human_decisions = state.get("humanDecisions") or []
    state_history = state.get("stateHistory", [])
    current_state = state.get("currentState", "")
    current_sn = _parse_state_num(current_state)
    metadata = state.get("metadata") or {}

    # Artifact presence stats
    artifacts_present = 0
    artifacts_expected = 0
    for g in gates:
        gate_id = g.get("gateId", "")
        threshold = GATE_STATE_THRESHOLD.get(gate_id, 999)
        if current_sn >= 0 and current_sn >= threshold:
            for art in g.get("artifacts", []):
                artifacts_expected += 1
                full_path = os.path.join(feature_dir, art)
                basename = os.path.basename(art)
                if basename and basename != art:
                    if os.path.isfile(full_path):
                        artifacts_present += 1
                elif "reviews/" in art:
                    reviews_dir = os.path.join(feature_dir, "reviews")
                    if os.path.isdir(reviews_dir):
                        md_files = glob_fn(os.path.join(reviews_dir, "*.md"))
                        if any(_file_size(f) >= 200 for f in md_files):
                            artifacts_present += 1

    # Review findings
    all_findings = []
    for g in gates:
        for f in g.get("findings", []):
            all_findings.append(f)
    grill_findings = [f for f in all_findings if f.get("source") == "grill-me"]
    review_findings = [f for f in all_findings if f.get("source") == "code-review"]
    relevant = grill_findings + review_findings
    p0_count = sum(1 for f in relevant if f.get("severity") == "P0")
    p1_count = sum(1 for f in relevant if f.get("severity") == "P1")

    # Retry stats
    retry_history = feedback_loop.get("retryHistory", [])
    retry_total = len(retry_history)
    retry_pass = sum(1 for r in retry_history if r.get("result") == "passed")
    retry_escalated = sum(1 for r in retry_history if r.get("result") == "escalated")

    # Stall
    stalled_since = feedback_loop.get("stalledSince")
    stalled_hours = None
    if stalled_since:
        stalled_dt = _iso_to_dt(stalled_since)
        if stalled_dt:
            now = datetime.now(timezone.utc)
            stalled_hours = round(_hours_between(stalled_dt, now), 1)

    # Time elapsed
    elapsed_hours = None
    if state_history:
        t_start = _iso_to_dt(state_history[0].get("timestamp"))
        completed_at = state.get("completedAt")
        updated_at = state.get("updatedAt")
        t_end = None
        if completed_at:
            t_end = _iso_to_dt(completed_at)
        if t_end is None and updated_at:
            t_end = _iso_to_dt(updated_at)
        if t_end is None:
            t_end = _iso_to_dt(state_history[-1].get("timestamp"))
        if t_start and t_end:
            elapsed_hours = round((t_end - t_start).total_seconds() / 3600.0, 1)

    # Token usage
    token_usage = metadata.get("tokenUsage", {})
    total_tokens = None
    if token_usage:
        total_tokens = token_usage.get("totalInputTokens", 0) + token_usage.get("totalOutputTokens", 0)

    # ADR / Retro
    adr_path = os.path.join(feature_dir, "06-adr.md")
    retro_path = os.path.join(feature_dir, "07-task-retro.md")
    adr_exists = os.path.isfile(adr_path)
    retro_exists = os.path.isfile(retro_path)

    # Experience pipeline stats (S8/S9)
    exp_stats = None
    if current_sn >= 8:
        script_dir = Path(__file__).resolve().parent
        workflow_dir = script_dir.parent
        experience_dir = workflow_dir / "experience"
        exp_stats = {}
        for sub in ["lessons", "patterns", "instincts"]:
            sub_dir = experience_dir / sub
            if sub_dir.is_dir():
                exp_stats[f"{sub}Count"] = len(list(sub_dir.glob("*.md")))
            else:
                exp_stats[f"{sub}Count"] = 0

    raw = {
        "featureId": state.get("featureId", ""),
        "currentState": current_state,
        "mode": state.get("mode", "unknown"),
        "orchestrator": state.get("orchestrator", "unknown"),
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
        "reviewP0Count": p0_count,
        "reviewP1Count": p1_count,
        "fallbackEventCount": len(fallback_events),
        "singleAgentSwitchCount": sum(
            1 for e in fallback_events
            if e.get("resolution") == "single-agent-mode"
        ),
        "humanDecisionCount": len(human_decisions),
        "retryTotal": retry_total,
        "retrySuccess": retry_pass,
        "retryEscalated": retry_escalated,
        "feedbackInjected": feedback_loop.get("feedbackInjected", False),
        "stalledHours": stalled_hours,
        "elapsedHours": elapsed_hours,
        "totalTokens": total_tokens,
        "complexity": metadata.get("complexity", "medium"),
        "adrExists": adr_exists,
        "adrSizeBytes": _file_size(adr_path) if adr_exists else 0,
        "retroExists": retro_exists,
        "retroSizeBytes": _file_size(retro_path) if retro_exists else 0,
    }

    if exp_stats:
        raw["experiencePipeline"] = exp_stats

    return raw


# ============================================================================
# Null Score (feature-state.json missing or unparseable)
# ============================================================================

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
        "engine": "scoring-engine-v2",
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
        "vetoStatus": {
            "triggered": False,
            "vetoType": None,
            "totalOverride": None,
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


# ============================================================================
# Main Scoring Function
# ============================================================================

def score_feature(feature_dir, baseline=None):
    """
    Score a single feature given its folder path.

    Args:
        feature_dir: Path to the feature folder (must contain feature-state.json).
        baseline: Optional baseline dict loaded from baselines.json.

    Returns:
        dict: The score.json object (v2 format).
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
    fdir = str(feature_dir)

    extra_info = {}

    # ---- D1: Process Integrity ----
    d1_score = _score_process_integrity(state, fdir)

    # ---- D2: Artifact Quality ----
    d2_result = _score_artifact_quality(state, fdir)
    if isinstance(d2_result, tuple):
        d2_score, d2_extra = d2_result
        extra_info["d2_extra"] = d2_extra
    else:
        d2_score = d2_result

    # ---- D3: Code Correctness ----
    d3_result = _score_code_correctness(state, fdir)
    if isinstance(d3_result, tuple):
        d3_score, d3_extra = d3_result
        extra_info["d3_extra"] = d3_extra
    else:
        d3_score = d3_result

    # ---- D4: Efficiency ----
    d4_extra = None
    d4_score = None
    d4_result = _score_efficiency(state)
    if isinstance(d4_result, tuple):
        d4_score, d4_extra = d4_result
    else:
        d4_score = d4_result

    # ---- D5: Security Compliance ----
    d5_result = _score_security_compliance(state, fdir)
    if isinstance(d5_result, tuple) and len(d5_result) == 3:
        d5_score, d5_violations, d5_veto = d5_result
    else:
        d5_score = d5_result
        d5_violations = []
        d5_veto = {"triggered": False, "vetoType": None, "totalOverride": None}

    # ---- D6: Iteration Capability ----
    d6_extra = None
    d6_score = None
    d6_result = _score_iteration_capability(state)
    if isinstance(d6_result, tuple):
        d6_score, d6_extra = d6_result
    else:
        d6_score = d6_result

    # ---- D7: Interface Acceptance ----
    d7_extra = None
    d7_score = None
    d7_result = _score_interface_acceptance(state, fdir)
    if isinstance(d7_result, tuple):
        d7_score, d7_extra = d7_result
    else:
        d7_score = d7_result

    # Build raw scores dict
    raw_scores = {
        "processIntegrity": d1_score,
        "artifactQuality": d2_score,
        "codeCorrectness": d3_score,
        "efficiency": d4_score,
        "securityCompliance": d5_score,
        "iterationCapability": d6_score,
        "interfaceAcceptance": d7_score,
    }

    # ---- Weighted Total ----
    total, dimensions = _weighted_total(raw_scores, WEIGHTS)

    # ---- One-Vote Veto (D5) ----
    veto_status = d5_veto.copy() if d5_veto else {"triggered": False, "vetoType": None, "totalOverride": None}

    # D1+D5 double breach check
    current_sn = _parse_state_num(state.get("currentState", ""))
    d1_inconsistencies = 0
    if current_sn >= 0:
        gates = state.get("gates", [])
        for g in gates:
            if g.get("status") == "passed":
                for art in g.get("artifacts", []):
                    full_path = os.path.join(fdir, art)
                    basename = os.path.basename(art)
                    if basename and basename != art and not os.path.isfile(full_path):
                        d1_inconsistencies += 1
    d5_l1_count = sum(
        1 for v in d5_violations if v.get("level") == "L1_SERIOUS"
    ) if d5_violations else 0

    if d1_inconsistencies >= 3 and d5_l1_count >= 1:
        veto_status["triggered"] = True
        veto_status["vetoType"] = "D1_D5_DOUBLE_BREACH"
        veto_status["totalOverride"] = 0

    # Apply veto override to total
    if veto_status.get("triggered") and veto_status.get("totalOverride") is not None:
        total = veto_status["totalOverride"]

    # ---- Deterministic Hash ----
    hash_parts = [feature_id]
    for dim in DIMENSION_ORDER:
        val = raw_scores.get(dim)
        hash_parts.append(str(val) if val is not None else "null")
    hash_input = "|".join(hash_parts)
    det_hash = hashlib.sha256(hash_input.encode("utf-8")).hexdigest()[:12]

    # ---- Baseline Comparison ----
    baseline_comparison = _compare_baseline(total, raw_scores, baseline)

    # ---- Warnings ----
    warnings = _collect_warnings(state, raw_scores, extra_info, fdir)

    # Post-scoring: quality-watch
    if baseline_comparison and baseline_comparison.get("status") not in (None, "no_baseline"):
        b_total = baseline_comparison.get("baselineTotal", 0)
        if total is not None and total < b_total - 15:
            warnings.append({
                "dimension": None,
                "code": "QUALITY_WATCH",
                "message": f"总分 {total} 低于基线 {b_total} 超过 15 分",
                "severity": "P1",
            })

    # ---- Raw Inputs ----
    raw_inputs = _collect_raw_inputs(state, raw_scores, fdir)

    # ---- Build dimensions output with extras ----
    final_dimensions = {}
    for dim in DIMENSION_ORDER:
        base = dimensions.get(dim, {
            "score": raw_scores.get(dim),
            "weight": WEIGHTS.get(dim, 0.0),
            "weighted": 0.0,
            "status": "null_not_applicable" if raw_scores.get(dim) is None else "scored",
        })

        # Attach sub-scores / extras
        if dim == "artifactQuality" and "d2_extra" in extra_info:
            base.update(extra_info["d2_extra"])
        if dim == "codeCorrectness" and "d3_extra" in extra_info:
            base.update(extra_info["d3_extra"])
        if dim == "efficiency" and d4_extra:
            base.update(d4_extra)
        if dim == "securityCompliance" and d5_violations:
            base["violations"] = d5_violations
        if dim == "iterationCapability" and d6_extra:
            base.update(d6_extra)
        if dim == "interfaceAcceptance" and d7_extra:
            base.update(d7_extra)

        # Add reason for null
        if base.get("score") is None and "reason" not in base:
            if current_sn < 6 and dim in ("codeCorrectness", "interfaceAcceptance"):
                base["reason"] = "功能未推进到 S6"

        final_dimensions[dim] = base

    return {
        "engine": "scoring-engine-v2",
        "scoredAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "scoredBy": "script:score.py",
        "featureId": feature_id,
        "llmCalls": 0,
        "deterministicHash": det_hash,
        "scores": {
            "total": total,
            "grade": _grade(total),
            "dimensions": final_dimensions,
        },
        "vetoStatus": veto_status,
        "baselineComparison": baseline_comparison,
        "warnings": warnings,
        "rawInputs": raw_inputs,
    }


# ============================================================================
# All-Features Scoring
# ============================================================================

def score_all_features(workflow_root, baseline=None, output_dir=None):
    """
    Score all features under workflow/features/.

    Args:
        workflow_root: Path to the workflow/ directory.
        baseline: Optional baseline dict.
        output_dir: Optional output directory for score.json files.

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
        total_str = str(score['scores']['total'])
        grade_str = str(score['scores']['grade'])
        print(f"Scored {feature_dir.name}: total={total_str}, grade={grade_str} -> {out_path}")

    return results


# ============================================================================
# CLI Entry Point
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Deterministic Scoring Engine v2 — scores feature product trustworthiness, "
                    "code verifiability, and security compliance.",
    )
    parser.add_argument(
        "--feature", type=str,
        help="Feature ID to score (single feature mode).",
    )
    parser.add_argument(
        "--all", action="store_true",
        help="Score all features under workflow/features/.",
    )
    parser.add_argument(
        "--baseline", type=str, default=None,
        help="Path to baselines.json (optional).",
    )
    parser.add_argument(
        "--output", type=str, default=None,
        help="Output path for score.json (single feature mode).",
    )
    parser.add_argument(
        "--output-dir", type=str, default=None,
        help="Output directory for score.json files (--all mode).",
    )
    parser.add_argument(
        "--live-check", action="store_true",
        help="Enable live build/test execution (requires build-command.txt / test-command.txt).",
    )

    args = parser.parse_args()

    if not args.feature and not args.all:
        parser.print_help()
        print("\nError: must specify --feature or --all", file=sys.stderr)
        sys.exit(1)

    # Resolve workflow root
    script_dir = Path(__file__).resolve().parent  # workflow/eval/
    workflow_root = script_dir.parent              # workflow/

    # Load baseline
    baseline = None
    if args.baseline:
        baseline_path = Path(args.baseline)
        if baseline_path.is_file():
            try:
                baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError) as e:
                print(f"Warning: could not parse baseline file: {e}", file=sys.stderr)
        else:
            candidate = script_dir / args.baseline
            if candidate.is_file():
                try:
                    baseline = json.loads(candidate.read_text(encoding="utf-8"))
                except (json.JSONDecodeError, UnicodeDecodeError):
                    pass
            if baseline is None:
                print(f"Warning: baseline file not found: {args.baseline}", file=sys.stderr)
    else:
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

        total_str = str(result['scores']['total'])
        grade_str = str(result['scores']['grade'])
        print(f"Scored {args.feature}: total={total_str}, grade={grade_str}")
        print(f"Output: {out_path}")

        if result.get("warnings"):
            print(f"Warnings: {len(result['warnings'])}")
            for w in result["warnings"]:
                print(f"  [{w.get('code')}] {w.get('message')}")

        if result.get("vetoStatus", {}).get("triggered"):
            print(f"VETO TRIGGERED: {result['vetoStatus'].get('vetoType')}")

        # Print full JSON to stdout for pipeline consumption
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
