#!/usr/bin/env bash
# ============================================================================
# dispatch.sh — 确定性路由调度器（零 LLM 调用）
# ============================================================================
# 这是整个工作流从"软约束"变"硬约束"的关键。它读取 feature-state.json，
# 输出机器可读的 JSON 路由指令。Agent 不再自己阅读 dispatcher.md 然后判断——
# Agent 直接执行 dispatch.sh 的输出。
#
# 设计原则：
#   1. 零 LLM 调用——纯文件系统 + 确定性 if/else 决策树
#   2. fail-closed——任何不确定状态 → 停止 → 要求人类介入
#   3. 文件系统是唯一真相源——产物文件在不在比任何元数据字段都可靠
#   4. 纯 Bash，兼容 Git Bash on Windows——jq 优先，不可用时降级为 grep/sed
#   5. 所有路由逻辑硬编码（不读 dispatcher.md，逻辑写死在脚本中）
#   6. 输出 JSON 是机器可读的确定性指令——Agent 不自行判断，直接执行
#
# 用法：
#   bash workflow/scripts/dispatch.sh <feature-id> [--json]
#
# 退出码：
#   0 — 路由指令生成成功，无阻塞
#   1 — 路由指令生成成功，但有警告或阻塞
#   2 — 脚本自身错误（参数错误、文件缺失、解析失败）
# ============================================================================

set -o pipefail

# ---- Path Configuration -----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FEATURES_DIR="$PROJECT_ROOT/workflow/features"
HANDOFFS_DIR="$PROJECT_ROOT/workflow/handoffs"
GATE_CHECK="$SCRIPT_DIR/gate-check.sh"
STATE_MACHINE="$PROJECT_ROOT/workflow/state-machine.md"

# ---- Tool Detection ---------------------------------------------------------
HAS_JQ=false
command -v jq >/dev/null 2>&1 && HAS_JQ=true

# ---- Global State -----------------------------------------------------------
WARNINGS=()
ERRORS=()
JSON_OUTPUT=false
GC_PASSED="fail"
GC_GATES_CHECKED=0
GC_PASSED_COUNT=0
GC_FAILED_COUNT=0
GC_OUTPUT=""

# ============================================================================
# SECTION 1: Helper Functions
# ============================================================================

# JSON string escape — pure sed, zero external deps
json_escape() {
    local input="$1"
    printf '%s' "$input" \
        | sed 's/\\/\\\\/g' \
        | sed 's/"/\\"/g' \
        | sed 's/\x09/\\t/g' \
        | sed 's/\x0D//g' \
        | sed ':a;N;$!ba;s/\n/\\n/g'
}

# Build a JSON array from arguments: json_arr "a" "b" "c" → ["a","b","c"]
json_arr() {
    local first=true
    local out="["
    for item in "$@"; do
        [ -z "$item" ] && continue
        if [ "$first" = true ]; then first=false; else out+=","; fi
        local escaped
        escaped=$(json_escape "$item")
        out+="\"$escaped\""
    done
    out+="]"
    printf '%s' "$out"
}

# Build a JSON object from flat key-value pairs: json_obj key1 val1 key2 val2 ...
# Special markers: ":arr:" prefix on value → JSON array; ":obj:" → raw JSON object; ":bool:" → boolean
json_obj() {
    local out="{"
    local first=true
    while [ $# -ge 2 ]; do
        local key="$1"
        local val="$2"
        shift 2
        if [ "$first" = true ]; then first=false; else out+=","; fi
        local escaped_key
        escaped_key=$(json_escape "$key")
        out+="\"$escaped_key\":"
        case "$val" in
            ":null:") out+="null" ;;
            ":true:") out+="true" ;;
            ":false:") out+="false" ;;
            :arr:\ *) out+="${val#:arr: }" ;;
            :obj:\ *) out+="${val#:obj: }" ;;
            :num:\ *) out+="${val#:num: }" ;;
            *) out+="\"$(json_escape "$val")\"" ;;
        esac
    done
    out+="}"
    printf '%s' "$out"
}

# Append a warning to global list
warn() { WARNINGS+=("$1"); }

# Append an error to global list
err() { ERRORS+=("$1"); }

# Get file modification time as epoch seconds (cross-platform)
file_mtime() {
    local file="$1"
    if [ -f "$file" ]; then
        # Try GNU date (Linux, Git Bash)
        date -r "$file" +%s 2>/dev/null && return
        # Try stat (BSD/macOS)
        stat -c %Y "$file" 2>/dev/null && return
        # Try stat BSD format
        stat -f %m "$file" 2>/dev/null && return
        # Fallback
        echo "0"
    else
        echo "0"
    fi
}

# Check if a file exists and is non-empty
file_exists_nonempty() {
    [ -f "$1" ] && [ -s "$1" ]
}

# ============================================================================
# SECTION 2: JSON Parsing (jq or grep/sed fallback)
# ============================================================================

# Extract a top-level string field from a JSON file
# Usage: json_get_string <file> <field> [default]
# Tries jq first, falls back to grep+sed if jq fails or is unavailable
json_get_string() {
    local file="$1"
    local field="$2"
    local default="${3:-}"

    if [ ! -f "$file" ]; then
        echo "$default"
        return
    fi

    # Try jq if available
    if [ "$HAS_JQ" = true ]; then
        local val
        val=$(jq -r ".$field // empty" "$file" 2>/dev/null)
        if [ -n "$val" ] && [ "$val" != "null" ]; then
            echo "$val"
            return
        fi
        # jq returned empty or failed — fall through to grep/sed
    fi

    # grep+sed fallback: match "field": "value"
    # Handle both "field":"value" and "field": "value"
    local val
    val=$(grep "\"$field\"" "$file" 2>/dev/null | head -1 | \
          sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"\]*\)".*/\1/')
    if [ -n "$val" ] && [ "$val" != "$(head -1 "$file" 2>/dev/null)" ]; then
        echo "$val"
        return
    fi
    echo "$default"
}

# Extract a numeric field from JSON
json_get_number() {
    local file="$1"
    local field="$2"
    local default="${3:-0}"

    if [ ! -f "$file" ]; then
        echo "$default"
        return
    fi

    # Try jq if available
    if [ "$HAS_JQ" = true ]; then
        local val
        val=$(jq -r ".$field" "$file" 2>/dev/null)
        if [ -n "$val" ] && [ "$val" != "null" ]; then
            echo "$val"
            return
        fi
        # jq returned empty or failed — fall through to grep/sed
    fi

    # grep+sed fallback
    local val
    val=$(grep "\"$field\"" "$file" 2>/dev/null | head -1 | \
          sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/')
    if [ -n "$val" ]; then
        echo "$val"
        return
    fi
    echo "$default"
}

# Extract a boolean field from JSON
json_get_bool() {
    local file="$1"
    local field="$2"
    local default="${3:-false}"

    if [ ! -f "$file" ]; then
        echo "$default"
        return
    fi

    # Try jq if available
    if [ "$HAS_JQ" = true ]; then
        local val
        val=$(jq -r ".$field // \"__UNDEF__\"" "$file" 2>/dev/null)
        if [ "$val" != "__UNDEF__" ] && [ "$val" != "null" ]; then
            echo "$val"
            return
        fi
        # jq returned empty or failed — fall through to grep/sed
    fi

    # grep+sed fallback
    if grep "\"$field\"" "$file" 2>/dev/null | head -1 | grep -q 'true'; then
        echo "true"
        return
    fi
    echo "$default"
}

# Check if feature-state.json has valid structure (basic schema validation)
validate_state_structure() {
    local file="$1"
    local issues=()

    if [ ! -f "$file" ]; then
        issues+=("feature-state.json 不存在")
        printf '%s\n' "${issues[@]}"
        return 1
    fi

    # Check it starts with {
    local first_char
    first_char=$(head -c 1 "$file" 2>/dev/null | tr -d '[:space:]')
    if [ "$first_char" != "{" ]; then
        issues+=("feature-state.json 不以 JSON 对象开头")
    fi

    # Check required fields exist
    for field in "featureId" "currentState" "orchestrator" "mode" "gates" "stateHistory"; do
        if ! grep -q "\"$field\"" "$file" 2>/dev/null; then
            issues+=("feature-state.json 缺少必需字段 '$field'")
        fi
    done

    # Validate currentState enum
    local state
    state=$(json_get_string "$file" "currentState")
    if [ -n "$state" ]; then
        case "$state" in
            S0|S1|S2|S3|S4|S5|S6|S7|S8|S9) : ;;
            *) issues+=("currentState='$state' 非标准状态值（期望 S0-S9）") ;;
        esac
    fi

    # Validate orchestrator enum
    local orch
    orch=$(json_get_string "$file" "orchestrator")
    if [ -n "$orch" ]; then
        case "$orch" in
            codex|claude) : ;;
            *) issues+=("orchestrator='$orch' 非标准值（期望 codex | claude）") ;;
        esac
    fi

    # Validate mode enum
    local mode
    mode=$(json_get_string "$file" "mode")
    if [ -n "$mode" ]; then
        case "$mode" in
            dual-agent|single-agent) : ;;
            *) issues+=("mode='$mode' 非标准值（期望 dual-agent | single-agent）") ;;
        esac
    fi

    # Validate gates array has 7 items (basic check)
    local gate_count
    if [ "$HAS_JQ" = true ]; then
        gate_count=$(jq '.gates | length' "$file" 2>/dev/null || echo "0")
    else
        gate_count=$(grep -c '"gateId"' "$file" 2>/dev/null || echo "0")
    fi
    if [ "${gate_count:-0}" -ne 7 ]; then
        issues+=("gates 数组长度为 $gate_count，预期 7")
    fi

    printf '%s\n' "${issues[@]}"
    if [ ${#issues[@]} -gt 0 ]; then
        return 1
    fi
    return 0
}

# ============================================================================
# SECTION 3: Agent Identity Detection
# ============================================================================

detect_agent_identity() {
    # P0: Explicit environment marker for Claude Code
    if [ -n "${CLAUDE_CODE_SESSION:-}" ]; then
        echo "claude"
        return
    fi

    # P1: Anthropic-specific markers (Claude Code context)
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        # Check if this looks like a Claude Code session (additional signal)
        if [ -n "${CLAUDE_CODE_AGENT_SKILL:-}" ] || [ -n "${CLAUDE_CODE_WORKFLOW:-}" ]; then
            echo "claude"
            return
        fi
    fi

    # P1: Codex session marker
    if [ -n "${CODEX_SESSION:-}" ] || [ -n "${CODEX_API_KEY:-}" ]; then
        echo "codex"
        return
    fi

    # P2: Check hostname for clues
    local hostname
    hostname=$(hostname 2>/dev/null || echo "")
    if echo "$hostname" | grep -qi "codex"; then
        echo "codex"
        return
    fi

    # P3: Check whoami / USER
    local user
    user=$(whoami 2>/dev/null || echo "${USER:-}")
    if echo "$user" | grep -qi "codex"; then
        echo "codex"
        return
    fi

    # P4: Default — assume Claude. Most invocations of this script are from Claude Code.
    # The orchestrator comparison will catch mismatches.
    echo "claude"
}

# Determine the session role
determine_role() {
    local orchestrator="$1"
    local agent="$2"

    if [ "$agent" = "unknown" ]; then
        echo "unknown"
        return
    fi
    if [ "$orchestrator" = "unknown" ]; then
        echo "unknown"
        return
    fi
    if [ "$orchestrator" = "$agent" ]; then
        echo "orchestrator"
    else
        echo "challenger"
    fi
}

# ============================================================================
# SECTION 4: Reachability Detection (Pure File-System Signals)
# ============================================================================

# Detect if the other agent is reachable or has returned
# Sets global variables: OTHER_AGENT, OTHER_REACHABLE, REGRESSION_DETECTED
OTHER_AGENT=""
OTHER_REACHABLE="unknown"
REGRESSION_DETECTED=false
LAST_HANDOFF_CHECK=0

detect_reachability() {
    local state_file="$1"
    local mode="$2"
    local orchestrator="$3"
    local codex_status="$4"
    local claude_status="$5"

    # Determine "the other agent" identity
    if [ "$orchestrator" = "claude" ]; then
        OTHER_AGENT="codex"
    elif [ "$orchestrator" = "codex" ]; then
        OTHER_AGENT="claude"
    else
        OTHER_AGENT="unknown"
        OTHER_REACHABLE="unknown"
        return
    fi

    # Read lastHandoffCheck from state file or default to 0
    LAST_HANDOFF_CHECK=$(json_get_number "$state_file" "lastHandoffCheck" "0")

    # ---- P0: Handoff file mtime > lastHandoffCheck ----
    local handoff_from_other=""
    if [ "$OTHER_AGENT" = "codex" ]; then
        handoff_from_other="$HANDOFFS_DIR/codex-to-claude.md"
    else
        handoff_from_other="$HANDOFFS_DIR/claude-to-codex.md"
    fi

    local handoff_mtime
    handoff_mtime=$(file_mtime "$handoff_from_other")
    if [ "$handoff_mtime" -gt "$LAST_HANDOFF_CHECK" ] 2>/dev/null && [ -f "$handoff_from_other" ]; then
        OTHER_REACHABLE="reachable"
        # Only flag regression if we were previously in single-agent mode (caller sets this)
        return
    fi

    # ---- P1: fallbackEvents with resolvedAt ----
    if [ -f "$state_file" ]; then
        local has_resolved
        if [ "$HAS_JQ" = true ]; then
            has_resolved=$(jq -r '[.fallbackEvents[]? | select(.resolvedAt != null and .resolvedAt != "")] | length' "$state_file" 2>/dev/null || echo "0")
        else
            # grep for resolvedAt that has a non-null value
            has_resolved=$(grep -c '"resolvedAt"' "$state_file" 2>/dev/null | head -1)
            # Crude check: if there are more resolvedAt entries, check if any have actual timestamps
            if [ "$has_resolved" -gt 0 ] 2>/dev/null; then
                local unresolved_count
                unresolved_count=$(grep '"resolvedAt"' "$state_file" 2>/dev/null | grep -c 'null' || echo "0")
                has_resolved=$((has_resolved - unresolved_count))
            fi
        fi
        if [ "${has_resolved:-0}" -gt 0 ] 2>/dev/null; then
            OTHER_REACHABLE="reachable"
            # Only flag regression if we were previously in single-agent mode (caller sets this)
            return
        fi
    fi

    # ---- P2: gate-check output indicates changes ----
    # (handled implicitly — if gate-check now passes where it previously failed,
    #  that's evidence of activity. We check this in the gate-check integration.)

    # ---- P3: review file mtime updated ----
    local other_review=""
    if [ "$OTHER_AGENT" = "codex" ]; then
        other_review="$FEATURES_DIR/$(basename "$state_file" | grep -o '^[^/]*')/reviews/codex-review.md"
    else
        other_review="$FEATURES_DIR/$(basename "$state_file" | grep -o '^[^/]*')/reviews/claude-review.md"
    fi
    # Actually we need the feature-id to construct this path. We'll use it from the caller.

    # Default: check the respective status fields
    if [ "$OTHER_AGENT" = "codex" ] && [ "$codex_status" = "reachable" ]; then
        OTHER_REACHABLE="reachable"
    elif [ "$OTHER_AGENT" = "claude" ] && [ "$claude_status" = "reachable" ]; then
        OTHER_REACHABLE="reachable"
    else
        OTHER_REACHABLE="unreachable"
    fi
}

# More thorough reachability check with feature-id context
detect_reachability_full() {
    local state_file="$1"
    local feature_id="$2"
    local mode="$3"
    local orchestrator="$4"
    local codex_status="$5"
    local claude_status="$6"

    detect_reachability "$state_file" "$mode" "$orchestrator" "$codex_status" "$claude_status"

    # ---- P3 (extended): Check if the other agent's review file was updated ----
    if [ "$OTHER_REACHABLE" != "reachable" ] && [ -n "$feature_id" ]; then
        local other_review=""
        local feature_review_dir="$FEATURES_DIR/$feature_id/reviews"
        if [ "$OTHER_AGENT" = "codex" ]; then
            other_review="$feature_review_dir/codex-review.md"
        else
            other_review="$feature_review_dir/claude-review.md"
        fi
        local review_mtime
        review_mtime=$(file_mtime "$other_review")
        if [ "$review_mtime" -gt "$LAST_HANDOFF_CHECK" ] 2>/dev/null && [ -f "$other_review" ]; then
            OTHER_REACHABLE="reachable"
        fi
    fi

    # Regression detection: only valid when transitioning FROM single-agent mode
    # In single-agent mode, if the other agent suddenly shows signs of life → regression
    if [ "$mode" = "single-agent" ] && [ "$OTHER_REACHABLE" = "reachable" ]; then
        REGRESSION_DETECTED=true
    fi

    # In dual-agent mode, if the other agent is unreachable → potential degradation
    if [ "$mode" = "dual-agent" ] && [ "$OTHER_REACHABLE" = "unreachable" ]; then
        warn "dual-agent 模式下 $OTHER_AGENT 不可达，可能需要降级到 single-agent 模式"
    fi
}

# ============================================================================
# SECTION 5: Gate Check Integration
# ============================================================================

run_gate_check() {
    local feature_id="$1"

    if [ ! -f "$GATE_CHECK" ]; then
        err "gate-check.sh 不可用: $GATE_CHECK"
        GC_PASSED="fail"
        GC_OUTPUT="{}"
        return 2
    fi

    # Run gate-check.sh and capture output (separate stdout JSON from stderr warnings)
    GC_OUTPUT=$(bash "$GATE_CHECK" "$feature_id" 2>/dev/null)
    local gc_rc=$?

    # Parse summary fields
    if [ "$HAS_JQ" = true ]; then
        GC_PASSED=$(echo "$GC_OUTPUT" | jq -r '.summary.status // "fail"' 2>/dev/null)
        GC_GATES_CHECKED=$(echo "$GC_OUTPUT" | jq -r '.summary.gatesChecked // 0' 2>/dev/null)
        GC_PASSED_COUNT=$(echo "$GC_OUTPUT" | jq -r '.summary.passed // 0' 2>/dev/null)
        GC_FAILED_COUNT=$(echo "$GC_OUTPUT" | jq -r '.summary.failed // 0' 2>/dev/null)
    else
        # grep-based extraction from gate-check JSON output
        GC_PASSED=$(echo "$GC_OUTPUT" | grep -o '"summary"[[:space:]]*:[[:space:]]*{[^}]*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)"' | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        [ -z "$GC_PASSED" ] && GC_PASSED="fail"

        GC_GATES_CHECKED=$(echo "$GC_OUTPUT" | grep -o '"gatesChecked"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/.*:[[:space:]]*\([0-9]*\).*/\1/')
        [ -z "$GC_GATES_CHECKED" ] && GC_GATES_CHECKED=0

        GC_PASSED_COUNT=$(echo "$GC_OUTPUT" | grep -o '"passed"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/.*:[[:space:]]*\([0-9]*\).*/\1/')
        [ -z "$GC_PASSED_COUNT" ] && GC_PASSED_COUNT=0

        GC_FAILED_COUNT=$(echo "$GC_OUTPUT" | grep -o '"failed"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/.*:[[:space:]]*\([0-9]*\).*/\1/')
        [ -z "$GC_FAILED_COUNT" ] && GC_FAILED_COUNT=0
    fi

    if [ "$GC_PASSED" != "pass" ]; then
        GC_PASSED="fail"
    fi

    return $gc_rc
}

# Extract individual gate status from gate-check output
get_gate_status() {
    local gate_id="$1"  # e.g., "G1", "G2", ...

    if [ "$HAS_JQ" = true ] && [ -n "$GC_OUTPUT" ]; then
        local status
        status=$(echo "$GC_OUTPUT" | jq -r ".gates[] | select(.gate == \"$gate_id\") | .status // \"unknown\"" 2>/dev/null)
        if [ -n "$status" ] && [ "$status" != "null" ]; then
            echo "$status"
            return
        fi
    else
        # grep for gate-specific status in the flat JSON output
        local status
        status=$(echo "$GC_OUTPUT" | grep "\"gate\":\"$gate_id\"" | grep -o '"status":"[^"]*"' | sed 's/"status":"\([^"]*\)"/\1/')
        if [ -n "$status" ]; then
            echo "$status"
            return
        fi
    fi
    echo "unknown"
}

# Build the gateCheck.gates sub-object
build_gates_status_obj() {
    local out="{"
    local first=true
    for g in G1 G2 G3 G4 G5 G6 G7; do
        if [ "$first" = true ]; then first=false; else out+=","; fi
        local status
        status=$(get_gate_status "$g")
        out+="\"gate-${g#G}\":\"$status\""
    done
    out+="}"
    printf '%s' "$out"
}

# ============================================================================
# SECTION 6: State → Action Routing Table (Hardcoded)
# ============================================================================

# Map currentState to action for orchestrator role
get_orchestrator_action() {
    local state="$1"
    case "$state" in
        S0) echo "create-openspec" ;;
        S1) echo "complete-openspec" ;;
        S2) echo "grill-me" ;;
        S3) echo "amend-spec" ;;
        S4) echo "task-mapping" ;;
        S5) echo "implement" ;;
        S6) echo "review" ;;
        S7) echo "verify" ;;
        S8) echo "knowledge-capture" ;;
        S9) echo "archive" ;;
        *)  echo "unknown" ;;
    esac
}

# Map currentState to action description for orchestrator
get_orchestrator_description() {
    local state="$1"
    case "$state" in
        S0) echo "创建功能文件夹并填写 01-openspec-proposal.md。完成后执行状态转换 S0→S1" ;;
        S1) echo "完成 OpenSpec 提案。检查是否需要人类审批（全新功能需 Gate 1 Checkpoint）" ;;
        S2) echo "将提案发送给挑战者进行 grill-me 技术风险审查，产出 02-grill-me-report.md" ;;
        S3) echo "逐条处理 grill-me 发现（答复/接受/升级），修订 01-openspec-proposal.md" ;;
        S4) echo "编写 03-task-skill-map.md：每个任务必须有 owner、skill routes、files、tests、rollback" ;;
        S5) echo "按已批准的任务映射表逐任务实现，更新 04-implementation-plan.md" ;;
        S6) echo "将 diff + proposal + task map 发送给审查者，执行/等待代码审查" ;;
        S7) echo "运行测试和手动检查，填写 05-verification-log.md" ;;
        S8) echo "编写 06-adr.md（架构决策记录）和 07-task-retro.md（任务回顾）" ;;
        S9) echo "整理最终制品集，生成 PR 摘要/发布说明/归档说明" ;;
        *)  echo "未知状态: $state" ;;
    esac
}

# Map currentState to required reads for orchestrator
get_required_reads() {
    local state="$1"
    case "$state" in
        S0) echo "" ;;
        S1) echo "01-openspec-proposal.md" ;;
        S2) echo "01-openspec-proposal.md|02-grill-me-report.md" ;;
        S3) echo "01-openspec-proposal.md|02-grill-me-report.md" ;;
        S4) echo "01-openspec-proposal.md|03-task-skill-map.md" ;;
        S5) echo "01-openspec-proposal.md|03-task-skill-map.md|04-implementation-plan.md" ;;
        S6) echo "01-openspec-proposal.md|03-task-skill-map.md|04-implementation-plan.md|reviews/" ;;
        S7) echo "01-openspec-proposal.md|05-verification-log.md" ;;
        S8) echo "06-adr.md|07-task-retro.md" ;;
        S9) echo "all-artifacts" ;;
        *)  echo "" ;;
    esac
}

# Map orchestrator's currentState to challenger action
get_challenger_action() {
    local orch_state="$1"
    case "$orch_state" in
        S2) echo "grill-me-review" ;;
        S6) echo "code-review" ;;
        S8) echo "architecture-review" ;;
        S7) echo "verify-review" ;;
        *)  echo "wait" ;;
    esac
}

get_challenger_description() {
    local orch_state="$1"
    case "$orch_state" in
        S2) echo "读取 01-openspec-proposal.md，攻击提案寻找边缘情况、安全漏洞、性能瓶颈、数据丢失、规格缺口、契约断裂" ;;
        S6) echo "读取 diff、proposal、task map，对照规格检查代码变更，检查契约断裂、隐藏状态、认证漏洞" ;;
        S8) echo "读取 ADR、实现笔记、验证日志，压力测试架构决策的长期影响" ;;
        S7) echo "读取验证日志，重新运行/检查验证步骤，确认残余风险" ;;
        *)  echo "编排者当前在 $orch_state 状态，等待编排者推进到你参与的阶段（S2/S6/S8）" ;;
    esac
}

get_challenger_reads() {
    local orch_state="$1"
    case "$orch_state" in
        S2) echo "01-openspec-proposal.md" ;;
        S6) echo "01-openspec-proposal.md|03-task-skill-map.md|04-implementation-plan.md" ;;
        S8) echo "06-adr.md|07-task-retro.md|05-verification-log.md" ;;
        S7) echo "05-verification-log.md" ;;
        *)  echo "01-openspec-proposal.md" ;;
    esac
}

# Single-agent overrides for orchestrator
get_single_agent_action() {
    local state="$1"
    case "$state" in
        S2) echo "manual-grill" ;;
        S6) echo "self-review" ;;
        *)  get_orchestrator_action "$state" ;;
    esac
}

get_single_agent_description() {
    local state="$1"
    local base_desc
    base_desc=$(get_orchestrator_description "$state")
    case "$state" in
        S2) echo "[单Agent] 手动填写 02-grill-me-report.md（技术风险自审）。标记 source: manual-grill" ;;
        S6) echo "[单Agent] 执行换帽自审三轮：实现者→怀疑者→验证者。每项发现标记 single-agent。遵循 fallback-matrix.md 审查协议" ;;
        S7) echo "[单Agent] 执行静态审查 + 手动检查计划。标记 tests: manual-plan" ;;
        *)  echo "[单Agent] $base_desc" ;;
    esac
}

# ============================================================================
# SECTION 7: Human Checkpoint Detection
# ============================================================================

# Detect if human checkpoint should be triggered
# Returns: checkpoint type string, or "none"
detect_human_checkpoint() {
    local state="$1"
    local role="$2"
    local mode="$3"
    local retry_count="$4"
    local max_retries="$5"
    local gate_failed="$6"      # "true" if gate check failed
    local failed_gate="$7"      # which gate failed, e.g. "gate-4"
    local state_file="$8"

    # ---- Trigger: feedbackLoop.retryCount >= maxRetries ----
    if [ "${retry_count:-0}" -ge "${max_retries:-3}" ] 2>/dev/null && [ "$gate_failed" = "true" ]; then
        echo "feedback-loop-max-retries"
        return
    fi

    # ---- Trigger: State-specific human checkpoints ----
    if [ "$role" = "orchestrator" ]; then
        case "$state" in
            S1)
                # S1: 全新功能需要人类审批。检查是否有 Gate 1 的人类决策记录
                # 若没有 humanDecisions 中 gate-1 的条目 → 可能需要人类审批
                # 脚本无法判断"全新 vs 增量"，标记为 possible
                if [ -f "$state_file" ]; then
                    local has_gate1_decision
                    has_gate1_decision=$(grep -c '"gateId"[[:space:]]*:[[:space:]]*"gate-1"' "$state_file" 2>/dev/null || echo "0")
                    if [ "${has_gate1_decision:-0}" -eq 0 ] 2>/dev/null; then
                        echo "possible-gate-1-human-approval"
                        return
                    fi
                fi
                ;;
            S4)
                # S4: 领域知识缺口 或 涉及生产数据/计费/认证/部署凭证
                # 脚本无法自动判断，标记为 possible
                echo "possible-gate-3-domain-knowledge"
                return
                ;;
            S5)
                # S5: 任务耗时超过估算 2x
                # 脚本无法自动判断，标记为 possible
                echo "possible-task-effort-blowout"
                return
                ;;
            S6)
                # S6: 两份审查同时标记同一 P0
                # 检查 reviews/ 下的文件内容
                echo "possible-dual-p0-review-deadlock"
                return
                ;;
            S7)
                # S7: 验收标准验证失败
                if [ "$gate_failed" = "true" ] && [ "$failed_gate" = "gate-6" ]; then
                    echo "verification-failure"
                    return
                fi
                ;;
        esac
    fi

    echo "none"
}

# Build humanCheckpoint object based on trigger type
build_human_checkpoint() {
    local trigger="$1"
    local state="$2"
    local failed_gate="$3"
    local retry_count="$4"

    if [ "$trigger" = "none" ]; then
        echo ":null:"
        return
    fi

    local desc
    local checkpoint_state
    case "$trigger" in
        feedback-loop-max-retries)
            desc="门禁 $failed_gate 连续失败 $retry_count 次，已达到最大重试上限。需人类决策。"
            checkpoint_state="$state"
            ;;
        possible-gate-1-human-approval)
            desc="S1 阶段未检测到 Gate 1 人类审批记录。若为全新功能（非增量修改），需以学习型 Checkpoint 六段结构呈现设计决策供人类审批。"
            checkpoint_state="S1"
            ;;
        possible-gate-3-domain-knowledge)
            desc="S4 任务映射阶段。若任务需要两个 Agent 都不具备的领域专业知识，或涉及生产数据/计费/认证/部署凭证，需触发人类 Checkpoint。"
            checkpoint_state="S4"
            ;;
        possible-task-effort-blowout)
            desc="S5 实现阶段。若任务耗时超过估算 2x，需人类决策：终止/缩减范围/接受成本。"
            checkpoint_state="S5"
            ;;
        possible-dual-p0-review-deadlock)
            desc="S6 审查阶段。若两份审查同时标记同一 P0，需停止并等待人类签核。"
            checkpoint_state="S6"
            ;;
        verification-failure)
            desc="S7 验证阶段。验收标准验证失败，需人类决定豁免还是回退修复。"
            checkpoint_state="S7"
            ;;
        *)
            desc="未知 Checkpoint 触发: $trigger"
            checkpoint_state="$state"
            ;;
    esac

    local obj
    obj=$(json_obj \
        "trigger" "$trigger" \
        "state" "$checkpoint_state" \
        "description" "$desc" \
        "format" "learning-checkpoint-6-section" \
        "formatRef" "workflow/learning-checkpoints.md")
    echo ":obj: $obj"
}

# ============================================================================
# SECTION 8: Feedback Loop Analysis
# ============================================================================

analyze_feedback_loop() {
    local state_file="$1"
    local gate_passed="$2"

    RETRY_COUNT=$(json_get_number "$state_file" "feedbackLoop.retryCount" "0")
    MAX_RETRIES=$(json_get_number "$state_file" "feedbackLoop.maxRetries" "3")
    FEEDBACK_INJECTED=$(json_get_bool "$state_file" "feedbackLoop.feedbackInjected" "false")
    STALLED_SINCE=$(json_get_string "$state_file" "feedbackLoop.stalledSince" "")
    LAST_FAILURE_GATE=$(json_get_string "$state_file" "feedbackLoop.lastFailureGate" "")

    # If gate passes, retryCount should reset (informational — state file update is orchestrator's job)
    FEEDBACK_ACTIVE=false
    if [ "$gate_passed" = "fail" ]; then
        FEEDBACK_ACTIVE=true
    fi
}

# ============================================================================
# SECTION 9: State Consistency Validation
# ============================================================================

# Cross-check JSON gates vs file system reality
validate_consistency() {
    local state_file="$1"
    local feature_dir="$2"

    local inconsistencies=()

    # For each gate that the state file says is "passed", verify the artifact exists
    if [ "$HAS_JQ" = true ] && [ -f "$state_file" ]; then
        local gate_entries
        gate_entries=$(jq -r '.gates[] | "\(.gateId)|\(.status)"' "$state_file" 2>/dev/null)
        while IFS='|' read -r gate_id gate_status; do
            if [ "$gate_status" = "passed" ]; then
                # Verify artifact existence using gate-check's per-gate logic
                local gc_gate_status
                gc_gate_status=$(get_gate_status "${gate_id#gate-}")
                # Convert: gate-1 → G1
                local gid="G${gate_id#gate-}"
                gc_gate_status=$(get_gate_status "$gid")
                if [ "$gc_gate_status" = "fail" ]; then
                    inconsistencies+=("$gate_id JSON声称passed但文件系统检查为fail")
                fi
            fi
        done <<< "$gate_entries"
    fi

    if [ ${#inconsistencies[@]} -gt 0 ]; then
        for inc in "${inconsistencies[@]}"; do
            warn "状态不一致: $inc"
        done
        echo "true"
    else
        echo "false"
    fi
}

# ============================================================================
# SECTION 10: Main Dispatch Logic
# ============================================================================

main() {
    # ---- Parse Arguments ----
    if [ $# -lt 1 ]; then
        cat >&2 <<'USAGE'
用法: dispatch.sh <feature-id> [--json]

参数:
  feature-id    功能目录名（位于 workflow/features/<feature-id>/）
  --json        输出纯 JSON（默认同时输出到 stdout 和 stderr）

输出:
  JSON 路由指令，包含 featureId, currentState, mode, orchestrator,
  challenger, gateCheck, nextAction, regressionDetected, errors

退出码:
  0 — 成功，无阻塞
  1 — 成功，但有警告或阻塞
  2 — 脚本错误
USAGE
        exit 2
    fi

    local FEATURE_ID="$1"
    if [ "$2" = "--json" ]; then
        JSON_OUTPUT=true
    fi

    # ---- Step 1: Locate feature ----
    local FEATURE_DIR="$FEATURES_DIR/$FEATURE_ID"
    local STATE_FILE="$FEATURE_DIR/feature-state.json"

    # ---- Step 2: Handle missing feature ----
    if [ ! -d "$FEATURE_DIR" ]; then
        local output
        output=$(json_obj \
            "featureId" "$FEATURE_ID" \
            "currentState" "S0" \
            "mode" "unknown" \
            "orchestrator" "unknown" \
            "challenger" "unknown" \
            "gateCheck" ":obj: $(json_obj "passed" ":false:" "gates" ":obj: {}" "note" "功能目录不存在")" \
            "nextAction" ":obj: $(json_obj \
                "role" "orchestrator" \
                "action" "create-feature" \
                "description" "功能 '$FEATURE_ID' 不存在。创建 workflow/features/$FEATURE_ID/ 并初始化 feature-state.json。运行: mkdir -p $FEATURE_DIR/reviews && 参考 workflow/feature-state.schema.json 创建 feature-state.json" \
                "requiredReads" ":arr: $(json_arr "workflow/feature-state.schema.json" "workflow/state-machine.md" "workflow/templates/01-openspec-proposal.md")" \
                "blockers" ":arr: $(json_arr "功能目录缺失")" \
                "warnings" ":arr: $(json_arr "当前无活跃功能，进入新功能创建流程")" \
                "humanCheckpoint" ":null:")" \
            "regressionDetected" ":false:" \
            "errors" ":arr: $(json_arr "功能目录 $FEATURE_DIR 不存在")")

        echo "$output"
        exit 1
    fi

    # ---- Step 3: Read feature-state.json ----
    if [ ! -f "$STATE_FILE" ]; then
        local output
        output=$(json_obj \
            "featureId" "$FEATURE_ID" \
            "currentState" "S0" \
            "mode" "unknown" \
            "orchestrator" "unknown" \
            "challenger" "unknown" \
            "gateCheck" ":obj: $(json_obj "passed" ":false:" "gates" ":obj: {}" "note" "feature-state.json 不存在")" \
            "nextAction" ":obj: $(json_obj \
                "role" "orchestrator" \
                "action" "init-state" \
                "description" "feature-state.json 缺失。参考 workflow/feature-state.schema.json 创建初始状态文件（S0）。运行: 在 $FEATURE_DIR/ 下创建 feature-state.json" \
                "requiredReads" ":arr: $(json_arr "workflow/feature-state.schema.json" "workflow/state-machine.md" "workflow/dispatcher.md")" \
                "blockers" ":arr: $(json_arr "feature-state.json 缺失")" \
                "warnings" ":arr: $(json_arr "功能目录存在但 feature-state.json 缺失——需初始化状态文件")" \
                "humanCheckpoint" ":null:")" \
            "regressionDetected" ":false:" \
            "errors" ":arr: $(json_arr "feature-state.json 不存在于 $FEATURE_DIR")")

        echo "$output"
        exit 1
    fi

    # ---- Step 4: Validate state file structure ----
    local schema_issues
    schema_issues=$(validate_state_structure "$STATE_FILE" 2>&1)
    local schema_rc=$?
    if [ $schema_rc -ne 0 ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && warn "Schema 警告: $line"
        done <<< "$schema_issues"
    fi

    # ---- Step 5: Extract core fields ----
    local current_state
    current_state=$(json_get_string "$STATE_FILE" "currentState" "S0")

    local orchestrator
    orchestrator=$(json_get_string "$STATE_FILE" "orchestrator" "unknown")

    local challenger
    challenger=$(json_get_string "$STATE_FILE" "challenger" "unknown")

    local mode
    mode=$(json_get_string "$STATE_FILE" "mode" "dual-agent")

    local codex_status
    codex_status=$(json_get_string "$STATE_FILE" "codexStatus" "unknown")

    local claude_status
    claude_status=$(json_get_string "$STATE_FILE" "claudeStatus" "unknown")

    local mcp_status
    mcp_status=$(json_get_string "$STATE_FILE" "mcpStatus" "unknown")

    local feature_name
    feature_name=$(json_get_string "$STATE_FILE" "humanReadableName" "$FEATURE_ID")

    # ---- Step 6: Detect agent identity and determine role ----
    local agent_identity
    agent_identity=$(detect_agent_identity)

    local role
    role=$(determine_role "$orchestrator" "$agent_identity")

    if [ "$role" = "unknown" ]; then
        warn "无法确定当前 Agent 角色（agent=$agent_identity, orchestrator=$orchestrator）。请手动确认。"
        # Default to orchestrator to avoid deadlock
        if [ "$agent_identity" = "claude" ] || [ "$agent_identity" = "codex" ]; then
            role="orchestrator"
            warn "默认角色设置为 orchestrator（推定当前 Agent 为编排发起者）"
        fi
    fi

    # ---- Step 7: Detect reachability ----
    detect_reachability_full "$STATE_FILE" "$FEATURE_ID" "$mode" "$orchestrator" "$codex_status" "$claude_status"

    # ---- Step 8: Run gate check ----
    run_gate_check "$FEATURE_ID"
    local gate_rc=$?

    if [ $gate_rc -eq 2 ]; then
        err "gate-check.sh 执行失败"
    fi

    local gate_passed="$GC_PASSED"

    # ---- Step 9: Analyze feedback loop ----
    analyze_feedback_loop "$STATE_FILE" "$gate_passed"

    # ---- Step 10: State consistency validation ----
    local has_inconsistency
    has_inconsistency=$(validate_consistency "$STATE_FILE" "$FEATURE_DIR")
    if [ "$has_inconsistency" = "true" ]; then
        warn "检测到 JSON 状态与文件系统不一致——gate-check 的确定性输出为权威来源"
    fi

    # ---- Step 11: Determine which gate failed (if any) ----
    local failed_gate=""
    if [ "$gate_passed" = "fail" ]; then
        # Determine which gate failed from gate-check output
        if [ "$HAS_JQ" = true ] && [ -n "$GC_OUTPUT" ]; then
            failed_gate=$(echo "$GC_OUTPUT" | jq -r '.gates[] | select(.status == "fail") | .gate' 2>/dev/null | head -1)
        fi
        if [ -z "$failed_gate" ]; then
            # Fallback: find first gate that failed using grep
            failed_gate=$(echo "$GC_OUTPUT" | grep '"status":"fail"' | head -1 | grep -o '"gate":"[^"]*"' | sed 's/"gate":"\([^"]*\)"/\1/')
        fi
        # Normalize: G1 → gate-1
        if [ -n "$failed_gate" ]; then
            case "$failed_gate" in
                G[1-7]) failed_gate="gate-${failed_gate#G}" ;;
            esac
        fi
        [ -z "$failed_gate" ] && failed_gate="unknown"
    fi

    # ---- Step 12: Human checkpoint detection ----
    local checkpoint_trigger
    checkpoint_trigger=$(detect_human_checkpoint "$current_state" "$role" "$mode" \
        "$RETRY_COUNT" "$MAX_RETRIES" \
        "$([ "$gate_passed" = "fail" ] && echo "true" || echo "false")" \
        "$failed_gate" "$STATE_FILE")

    local human_checkpoint_json
    human_checkpoint_json=$(build_human_checkpoint "$checkpoint_trigger" "$current_state" "$failed_gate" "$RETRY_COUNT")

    # ---- Step 13: Build nextAction ----
    local next_action=""
    local next_description=""
    local next_reads=""
    local next_role="$role"

    if [ "$role" = "orchestrator" ]; then
        if [ "$mode" = "single-agent" ]; then
            next_action=$(get_single_agent_action "$current_state")
            next_description=$(get_single_agent_description "$current_state")
        else
            next_action=$(get_orchestrator_action "$current_state")
            next_description=$(get_orchestrator_description "$current_state")
        fi
        next_reads=$(get_required_reads "$current_state")
    else
        # Challenger role
        next_action=$(get_challenger_action "$current_state")
        next_description=$(get_challenger_description "$current_state")
        next_reads=$(get_challenger_reads "$current_state")
    fi

    # ---- Step 13b: Gate failure overrides ----
    local blockers_arr="[]"
    local warnings_arr="[]"
    if [ "$gate_passed" = "fail" ] && [ "$role" = "orchestrator" ]; then
        if [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ] 2>/dev/null; then
            next_action="fix-gate-failure"
            next_description="门禁检查失败（$failed_gate）。retryCount=$RETRY_COUNT/$MAX_RETRIES。分析失败原因、注入修正、重新调用 gate-check.sh。见 feedback-loop.md 2.3"
            blockers_arr=$(json_arr "门禁 $failed_gate 未通过")
        else
            next_action="await-human-decision"
            next_description="门禁 $failed_gate 已连续失败 $RETRY_COUNT 次（上限 $MAX_RETRIES）。停止自动重试，等待人类决策。"
            blockers_arr=$(json_arr "门禁 $failed_gate 重试耗尽，等待人类决策")
        fi
    fi

    # ---- Step 13c: Build nextAction JSON ----
    # Build requiredReads array
    local reads_arr="[]"
    if [ -n "$next_reads" ]; then
        IFS='|' read -ra read_items <<< "$next_reads"
        reads_arr=$(json_arr "${read_items[@]}")
    fi

    # Build warnings
    local all_warnings=()
    if [ "$mode" = "single-agent" ] && [ "$role" = "orchestrator" ]; then
        all_warnings+=("mode single-agent: 所有审查需自审")
        if [ "$current_state" = "S6" ]; then
            all_warnings+=("单Agent审查: 执行换帽自审三轮（实现者→怀疑者→验证者），标记 single-agent")
        fi
    fi
    if [ "$OTHER_REACHABLE" = "unreachable" ] && [ "$mode" = "dual-agent" ]; then
        all_warnings+=("$OTHER_AGENT 当前不可达，若持续不可达需触发降级协议")
    fi
    for w in "${WARNINGS[@]}"; do
        all_warnings+=("$w")
    done

    local next_action_obj
    next_action_obj=$(json_obj \
        "role" "$next_role" \
        "action" "$next_action" \
        "description" "$next_description" \
        "requiredReads" ":arr: $reads_arr" \
        "blockers" ":arr: $blockers_arr" \
        "warnings" ":arr: $(json_arr "${all_warnings[@]}")" \
        "humanCheckpoint" "$human_checkpoint_json")

    # ---- Step 14: Build gateCheck ----
    local gates_status_obj
    gates_status_obj=$(build_gates_status_obj)

    local gate_check_obj
    gate_check_obj=$(json_obj \
        "passed" "$([ "$gate_passed" = "pass" ] && echo ":true:" || echo ":false:")" \
        "gates" ":obj: $gates_status_obj" \
        "gatesChecked" ":num: $GC_GATES_CHECKED" \
        "passedCount" ":num: $GC_PASSED_COUNT" \
        "failedCount" ":num: $GC_FAILED_COUNT")

    # ---- Step 15: Assemble final output ----
    local errors_json
    if [ ${#ERRORS[@]} -gt 0 ]; then
        errors_json=$(json_arr "${ERRORS[@]}")
    else
        errors_json="[]"
    fi

    local output
    output=$(json_obj \
        "featureId" "$FEATURE_ID" \
        "humanReadableName" "$feature_name" \
        "currentState" "$current_state" \
        "mode" "$mode" \
        "orchestrator" "$orchestrator" \
        "challenger" "$challenger" \
        "agentIdentity" "$agent_identity" \
        "sessionRole" "$role" \
        "codexStatus" "$codex_status" \
        "claudeStatus" "$claude_status" \
        "mcpStatus" "$mcp_status" \
        "otherAgent" "$OTHER_AGENT" \
        "otherReachable" "$OTHER_REACHABLE" \
        "gateCheck" ":obj: $gate_check_obj" \
        "nextAction" ":obj: $next_action_obj" \
        "regressionDetected" "$([ "$REGRESSION_DETECTED" = true ] && echo ":true:" || echo ":false:")" \
        "feedbackLoop" ":obj: $(json_obj \
            "retryCount" ":num: $RETRY_COUNT" \
            "maxRetries" ":num: $MAX_RETRIES" \
            "feedbackInjected" "$([ "$FEEDBACK_INJECTED" = "true" ] && echo ":true:" || echo ":false:")" \
            "active" "$([ "$FEEDBACK_ACTIVE" = true ] && echo ":true:" || echo ":false:")" \
            "lastFailureGate" "$LAST_FAILURE_GATE" \
            "stalledSince" "$([ -z "$STALLED_SINCE" ] && echo ":null:" || echo "$STALLED_SINCE")")" \
        "errors" ":arr: $errors_json")

    # ---- Step 16: Output ----
    echo "$output"

    # Determine exit code
    if [ ${#ERRORS[@]} -gt 0 ]; then
        exit 1
    elif [ "$gate_passed" = "fail" ] && [ "$role" = "orchestrator" ]; then
        exit 1
    elif [ ${#WARNINGS[@]} -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

# ============================================================================
# ENTRY POINT
# ============================================================================
main "$@"
