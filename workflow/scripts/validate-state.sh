#!/usr/bin/env bash
# ============================================================================
# validate-state.sh — feature-state.json 独立 Schema 校验脚本（零 LLM 调用）
# ============================================================================
# 设计原则：
#   1. 零 LLM 调用 —— 纯文件系统 + JSON 结构校验
#   2. 职责单一 —— 只做 Schema 校验，不做产物检查（产物检查由 gate-check.sh 负责）
#   3. 与 feature-state.schema.json 约束保持一致
#   4. 纯 Bash，jq 用于 JSON 解析（jq 不可用时降级为 python -m json.tool + grep）
#   5. --fix 模式自动修正可修复的结构问题
#
# 与 gate-check.sh --schema-only 的区别：
#   - gate-check.sh --schema-only 是 gate-check.sh 的子模式，侧重门禁上下文
#   - validate-state.sh 专门做 Schema 校验，粒度更细，校验项更多，支持 --fix
#
# 用法：
#   bash workflow/scripts/validate-state.sh <feature-id> [--json] [--fix]
#
# 参数：
#   feature-id      必需。功能目录名（位于 workflow/features/<feature-id>/）
#   --json          增强 JSON 输出（默认即 JSON，此标志保留兼容性）
#   --fix           自动修正可修复的结构问题
#
# 退出码：
#   0 — Schema 校验全部通过（无错误）
#   1 — 存在校验错误（schemaValid=false）
#   2 — 脚本自身错误（参数错误、目录不存在）
#   3 — 文件不存在
#
# ============================================================================

set -o pipefail

# ---- 路径配置 ---------------------------------------------------------------
FEATURES_DIR="${WORKFLOW_FEATURES_DIR:-workflow/features}"
SCRIPT_NAME="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---- 工具检测 ---------------------------------------------------------------
HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
    HAS_JQ=true
fi

HAS_PYTHON=false
if command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    HAS_PYTHON=true
fi

# 选择 python 可执行文件
PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
fi

# ---- 全局状态 ---------------------------------------------------------------
CHECKS_ARRAY=""           # 累积 {check, passed} 对象
CHECK_COUNT=0
ERRORS_ARRAY=""           # 错误消息数组
ERROR_COUNT=0
WARNINGS_ARRAY=""         # 警告消息数组
WARNING_COUNT=0
AUTOFIX_ARRAY=""          # autoFixed 消息数组
FIX_COUNT=0
SCHEMA_VALID=true
FIX_MODE=false
JSON_MODE=false

# ---- 校验常量 ---------------------------------------------------------------
VALID_STATES=("S0" "S1" "S2" "S3" "S4" "S5" "S6" "S7" "S8" "S9")
VALID_ORCHESTRATORS=("codex" "claude")
VALID_MODES=("dual-agent" "single-agent")
VALID_CHALLENGERS=("codex" "claude" "manual" "none")
VALID_GATE_IDS=("gate-1" "gate-2" "gate-3" "gate-4" "gate-5" "gate-6" "gate-7")
VALID_GATE_STATUSES=("pending" "passed" "failed" "skipped")
REQUIRED_FIELDS=("featureId" "currentState" "orchestrator" "challenger" "mode" "createdAt" "updatedAt" "gates" "stateHistory")
REQUIRED_GATE_FIELDS=("gateId" "status" "artifacts")

# ISO 8601 datetime regex（宽松匹配，接受 Z/+HH:MM/-HH:MM 后缀）
ISO8601_REGEX='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})?$'

# ---- 辅助函数 ---------------------------------------------------------------

# JSON 字符串转义
json_escape() {
    local input="$1"
    printf '%s' "$input" \
        | sed 's/\\/\\\\/g' \
        | sed 's/"/\\"/g' \
        | sed 's/\x09/\\t/g' \
        | sed 's/\x0D//g' \
        | sed ':a;N;$!ba;s/\n/\\n/g'
}

# 构建 JSON 字符串数组
json_str_array() {
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

# 追加一条校验结果到 checks 数组
append_check() {
    local check_name="$1"
    local passed="$2"
    local obj
    obj="{\"check\":\"$(json_escape "$check_name")\",\"passed\":$passed}"
    if [ "$CHECK_COUNT" -gt 0 ]; then
        CHECKS_ARRAY+=","
    fi
    CHECKS_ARRAY+="
        $obj"
    CHECK_COUNT=$((CHECK_COUNT + 1))
}

# 追加一条错误
append_error() {
    local msg="$1"
    ERRORS_ARRAY+="$( [ "$ERROR_COUNT" -gt 0 ] && echo "," )
        \"$(json_escape "$msg")\""
    ERROR_COUNT=$((ERROR_COUNT + 1))
    SCHEMA_VALID=false
}

# 追加一条警告
append_warning() {
    local msg="$1"
    WARNINGS_ARRAY+="$( [ "$WARNING_COUNT" -gt 0 ] && echo "," )
        \"$(json_escape "$msg")\""
    WARNING_COUNT=$((WARNING_COUNT + 1))
}

# 追加一条自动修复记录
append_autofix() {
    local msg="$1"
    AUTOFIX_ARRAY+="$( [ "$FIX_COUNT" -gt 0 ] && echo "," )
        \"$(json_escape "$msg")\""
    FIX_COUNT=$((FIX_COUNT + 1))
}

# 检查值是否在数组中
value_in_array() {
    local value="$1"
    shift
    for item in "$@"; do
        [ "$value" = "$item" ] && return 0
    done
    return 1
}

# 校验 ISO 8601 日期时间字符串
is_valid_iso8601() {
    local dt="$1"
    # 空或 null 视为可接受（可选字段可能为 null）
    if [ -z "$dt" ] || [ "$dt" = "null" ]; then
        return 0
    fi
    # 使用 bash 内置正则匹配
    if [[ "$dt" =~ $ISO8601_REGEX ]]; then
        return 0
    fi
    # 降级：用 grep -E 再试一次（兼容不含 [[ ]] 的旧版 bash）
    if echo "$dt" | grep -qE "$ISO8601_REGEX" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 获取当前 UTC 时间（ISO 8601 格式）
get_current_utc() {
    if [ "$HAS_PYTHON" = true ]; then
        $PYTHON_BIN -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null
    elif date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then
        : # date 命令已输出
    else
        # 最终降级：使用 bash 打印静态回退
        echo "1970-01-01T00:00:00Z"
    fi
}

# ---- 校验函数 ---------------------------------------------------------------

# 校验 1：JSON 是否可解析
check_json_parseable() {
    local state_file="$1"
    local passed=true

    if [ "$HAS_JQ" = true ]; then
        if ! jq empty "$state_file" 2>/dev/null; then
            passed=false
            local jq_error
            jq_error=$(jq empty "$state_file" 2>&1 || true)
            append_error "JSON 语法错误：文件无法被 jq 解析 —— $(json_escape "$jq_error")"
        fi
    elif [ "$HAS_PYTHON" = true ]; then
        if ! $PYTHON_BIN -m json.tool "$state_file" >/dev/null 2>&1; then
            passed=false
            local py_error
            py_error=$($PYTHON_BIN -m json.tool "$state_file" 2>&1 || true)
            append_error "JSON 语法错误：文件无法被 python -m json.tool 解析 —— $(json_escape "$py_error")"
        fi
    else
        # 无 jq 无 python：仅检查首字符
        local first_char
        first_char=$(head -c 1 "$state_file" 2>/dev/null | tr -d '[:space:]')
        if [ "$first_char" != "{" ]; then
            passed=false
            append_error "JSON 语法疑似错误：文件不以 '{' 开头（jq 和 python 均不可用，仅做首字符检查）"
        else
            append_warning "jq 和 python 均不可用，JSON 语法仅做首字符检查，精度有限"
        fi
    fi

    append_check "json-parseable" "$passed"
    $passed
}

# 校验 2：必需字段存在
check_required_fields() {
    local state_file="$1"
    local all_present=true

    for field in "${REQUIRED_FIELDS[@]}"; do
        local has_field=false
        if [ "$HAS_JQ" = true ]; then
            if jq -e ".$field" "$state_file" >/dev/null 2>&1; then
                # 额外检查：值不能是 null（对于必需字段）
                local fval
                fval=$(jq -r ".$field" "$state_file" 2>/dev/null)
                if [ "$fval" != "null" ]; then
                    has_field=true
                fi
            fi
        else
            if grep -q "\"$field\"" "$state_file" 2>/dev/null; then
                has_field=true
            fi
        fi

        if [ "$has_field" = false ]; then
            all_present=false
            append_error "缺少必需字段: '$field'"
        fi
    done

    append_check "required-fields" "$all_present"
    $all_present
}

# 校验 3：枚举值合法性
check_enum_values() {
    local state_file="$1"
    local all_valid=true

    if [ "$HAS_JQ" = true ]; then
        # currentState
        local state
        state=$(jq -r '.currentState // ""' "$state_file" 2>/dev/null)
        if [ -n "$state" ]; then
            if ! value_in_array "$state" "${VALID_STATES[@]}"; then
                all_valid=false
                append_error "currentState 非法枚举值: '$state'（预期 S0-S9）"
            fi
        fi

        # orchestrator
        local orch
        orch=$(jq -r '.orchestrator // ""' "$state_file" 2>/dev/null)
        if [ -n "$orch" ]; then
            if ! value_in_array "$orch" "${VALID_ORCHESTRATORS[@]}"; then
                all_valid=false
                append_error "orchestrator 非法枚举值: '$orch'（预期 codex 或 claude）"
            fi
        fi

        # challenger
        local chal
        chal=$(jq -r '.challenger // ""' "$state_file" 2>/dev/null)
        if [ -n "$chal" ] && [ "$chal" != "null" ]; then
            if ! value_in_array "$chal" "${VALID_CHALLENGERS[@]}"; then
                all_valid=false
                append_error "challenger 非法枚举值: '$chal'（预期 codex/claude/manual/none）"
            fi
        fi

        # mode
        local mode
        mode=$(jq -r '.mode // ""' "$state_file" 2>/dev/null)
        if [ -n "$mode" ]; then
            if ! value_in_array "$mode" "${VALID_MODES[@]}"; then
                all_valid=false
                append_error "mode 非法枚举值: '$mode'（预期 dual-agent 或 single-agent）"
            fi
        fi

        # codexStatus（可选字段）
        local cs
        cs=$(jq -r '.codexStatus // ""' "$state_file" 2>/dev/null)
        if [ -n "$cs" ] && [ "$cs" != "null" ]; then
            if ! value_in_array "$cs" "reachable" "unreachable" "degraded" "unknown"; then
                append_warning "codexStatus 非法枚举值: '$cs'（预期 reachable/unreachable/degraded/unknown）"
            fi
        fi

        # claudeStatus（可选字段）
        local cls
        cls=$(jq -r '.claudeStatus // ""' "$state_file" 2>/dev/null)
        if [ -n "$cls" ] && [ "$cls" != "null" ]; then
            if ! value_in_array "$cls" "reachable" "unreachable" "degraded" "unknown"; then
                append_warning "claudeStatus 非法枚举值: '$cls'（预期 reachable/unreachable/degraded/unknown）"
            fi
        fi

        # mcpStatus（可选字段）
        local mcp
        mcp=$(jq -r '.mcpStatus // ""' "$state_file" 2>/dev/null)
        if [ -n "$mcp" ] && [ "$mcp" != "null" ]; then
            if ! value_in_array "$mcp" "up" "down" "unknown"; then
                append_warning "mcpStatus 非法枚举值: '$mcp'（预期 up/down/unknown）"
            fi
        fi
    else
        # 降级：grep 提取后校验
        local state
        state=$(grep '"currentState"' "$state_file" 2>/dev/null | head -1 \
            | sed 's/.*"currentState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [ -n "$state" ] && ! value_in_array "$state" "${VALID_STATES[@]}"; then
            all_valid=false
            append_error "currentState 非法枚举值: '$state'（预期 S0-S9）[grep 降级校验]"
        fi

        local orch
        orch=$(grep '"orchestrator"' "$state_file" 2>/dev/null | head -1 \
            | sed 's/.*"orchestrator"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [ -n "$orch" ] && ! value_in_array "$orch" "${VALID_ORCHESTRATORS[@]}"; then
            all_valid=false
            append_error "orchestrator 非法枚举值: '$orch'（预期 codex/claude）[grep 降级校验]"
        fi

        local mode
        mode=$(grep '"mode"' "$state_file" 2>/dev/null | head -1 \
            | sed 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [ -n "$mode" ] && ! value_in_array "$mode" "${VALID_MODES[@]}"; then
            all_valid=false
            append_error "mode 非法枚举值: '$mode'（预期 dual-agent/single-agent）[grep 降级校验]"
        fi

        append_warning "jq 不可用，枚举值校验降级为 grep（不检查 challenger/codexStatus/claudeStatus/mcpStatus）"
    fi

    append_check "enum-values" "$all_valid"
    $all_valid
}

# 校验 4：gates 数组长度 == 7
check_gates_count() {
    local state_file="$1"
    local passed=true

    if [ "$HAS_JQ" = true ]; then
        local gate_count
        gate_count=$(jq '.gates | length' "$state_file" 2>/dev/null || echo "0")
        gate_count=$(echo "$gate_count" | tr -d '[:space:]')
        if [ "${gate_count:-0}" -ne 7 ]; then
            passed=false
            append_error "gates 数组长度为 $gate_count，预期 7"
        fi
    else
        # 降级：grep 计数 "gateId" 出现次数
        local gate_count
        gate_count=$(grep -c '"gateId"' "$state_file" 2>/dev/null || echo "0")
        gate_count=$(echo "$gate_count" | tr -d '[:space:]')
        if [ "${gate_count:-0}" -ne 7 ]; then
            passed=false
            append_error "gates 数组长度约为 $gate_count，预期 7 [grep 降级校验，精度有限]"
        fi
    fi

    append_check "gates-count" "$passed"
    $passed
}

# 校验 5：每个 gate 结构完整
check_gate_structure() {
    local state_file="$1"
    local all_valid=true

    if [ "$HAS_JQ" = true ]; then
        local gate_count
        gate_count=$(jq '.gates | length' "$state_file" 2>/dev/null || echo "0")
        gate_count=$(echo "$gate_count" | tr -d '[:space:]')

        if [ "${gate_count:-0}" -gt 0 ]; then
            for ((i=0; i<gate_count; i++)); do
                # 检查必需字段
                for field in "${REQUIRED_GATE_FIELDS[@]}"; do
                    local has_field
                    has_field=$(jq -r ".gates[$i].$field" "$state_file" 2>/dev/null)
                    if [ "$has_field" = "null" ] || [ -z "$has_field" ]; then
                        all_valid=false
                        append_error "gates[$i]: 缺少必需字段 '$field'"
                    fi
                done

                # 验证 gateId 枚举值
                local gid
                gid=$(jq -r ".gates[$i].gateId // \"\"" "$state_file" 2>/dev/null)
                if [ -n "$gid" ] && ! value_in_array "$gid" "${VALID_GATE_IDS[@]}"; then
                    all_valid=false
                    append_error "gates[$i].gateId 非法值: '$gid'（预期 gate-1 到 gate-7）"
                fi

                # 验证 status 枚举值
                local gs
                gs=$(jq -r ".gates[$i].status // \"\"" "$state_file" 2>/dev/null)
                if [ -n "$gs" ] && ! value_in_array "$gs" "${VALID_GATE_STATUSES[@]}"; then
                    all_valid=false
                    append_error "gates[$i].status 非法值: '$gs'（预期 pending/passed/failed/skipped）"
                fi

                # 验证 artifacts 是数组且非空
                local art_type
                art_type=$(jq -r "(.gates[$i].artifacts | type) // \"null\"" "$state_file" 2>/dev/null)
                if [ "$art_type" != "array" ]; then
                    all_valid=false
                    append_error "gates[$i].artifacts 不是数组类型（实际为 $art_type）"
                else
                    local art_len
                    art_len=$(jq ".gates[$i].artifacts | length" "$state_file" 2>/dev/null || echo "0")
                    art_len=$(echo "$art_len" | tr -d '[:space:]')
                    if [ "${art_len:-0}" -lt 1 ]; then
                        all_valid=false
                        append_error "gates[$i].artifacts 为空数组，应至少包含 1 个产物路径"
                    fi
                fi

                # 可选：检查 checkResults.schemaValid 和 checkResults.allArtifactsPresent 类型
                local cr_schema
                cr_schema=$(jq -r "(.gates[$i].checkResults.schemaValid | type) // \"null\"" "$state_file" 2>/dev/null)
                if [ "$cr_schema" != "null" ] && [ "$cr_schema" != "boolean" ]; then
                    append_warning "gates[$i].checkResults.schemaValid 应为 boolean 类型（实际为 $cr_schema）"
                fi

                local cr_artifacts
                cr_artifacts=$(jq -r "(.gates[$i].checkResults.allArtifactsPresent | type) // \"null\"" "$state_file" 2>/dev/null)
                if [ "$cr_artifacts" != "null" ] && [ "$cr_artifacts" != "boolean" ]; then
                    append_warning "gates[$i].checkResults.allArtifactsPresent 应为 boolean 类型（实际为 $cr_artifacts）"
                fi

                # 可选：验证时间字段格式
                for time_field in "enteredAt" "resolvedAt"; do
                    local tf_val
                    tf_val=$(jq -r ".gates[$i].$time_field // \"\"" "$state_file" 2>/dev/null)
                    if [ -n "$tf_val" ] && [ "$tf_val" != "null" ]; then
                        if ! is_valid_iso8601 "$tf_val"; then
                            append_warning "gates[$i].$time_field 不是合法 ISO 8601 日期: '$tf_val'"
                        fi
                    fi
                done
            done
        fi
    else
        # 降级：grep 基础检查
        for field in "${REQUIRED_GATE_FIELDS[@]}"; do
            if ! grep -q "\"$field\"" "$state_file" 2>/dev/null; then
                all_valid=false
                append_error "gates 数组中未找到字段 '$field' [grep 降级校验，精度有限]"
            fi
        done

        for gid in "${VALID_GATE_IDS[@]}"; do
            if ! grep -q "$gid" "$state_file" 2>/dev/null; then
                append_warning "gates 数组中未找到预期的 gateId: '$gid' [grep 降级校验]"
            fi
        done

        append_warning "jq 不可用，gate 结构校验降级为 grep（仅检查字段名存在性）"
    fi

    append_check "gate-structure" "$all_valid"
    $all_valid
}

# 校验 6：日期字段格式（ISO 8601）
check_date_format() {
    local state_file="$1"
    local all_valid=true

    if [ "$HAS_JQ" = true ]; then
        # 必需日期字段
        for field in "createdAt" "updatedAt"; do
            local fval
            fval=$(jq -r ".$field // \"\"" "$state_file" 2>/dev/null)
            if [ -n "$fval" ] && [ "$fval" != "null" ]; then
                if ! is_valid_iso8601 "$fval"; then
                    all_valid=false
                    append_error "$field 不是合法 ISO 8601 日期: '$fval'"
                fi
            fi
        done

        # 可选日期字段（不阻塞，仅警告）
        for field in "completedAt"; do
            local fval
            fval=$(jq -r ".$field // \"\"" "$state_file" 2>/dev/null)
            if [ -n "$fval" ] && [ "$fval" != "null" ]; then
                if ! is_valid_iso8601 "$fval"; then
                    append_warning "$field 不是合法 ISO 8601 日期: '$fval'"
                fi
            fi
        done
    else
        # 降级：grep 提取后做基础正则匹配
        for field in "createdAt" "updatedAt"; do
            local fval
            fval=$(grep "\"$field\"" "$state_file" 2>/dev/null | head -1 \
                | sed 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            if [ -n "$fval" ] && [ "$fval" != "null" ]; then
                if ! echo "$fval" | grep -qE "$ISO8601_REGEX" 2>/dev/null; then
                    all_valid=false
                    append_error "$field 不是合法 ISO 8601 日期: '$fval' [grep 降级校验]"
                fi
            fi
        done

        append_warning "jq 不可用，日期格式校验降级为 grep（仅检查 createdAt/updatedAt）"
    fi

    append_check "date-format" "$all_valid"
    $all_valid
}

# 校验 7：stateHistory 非空数组
check_state_history() {
    local state_file="$1"
    local passed=true

    if [ "$HAS_JQ" = true ]; then
        local hist_type
        hist_type=$(jq -r '(.stateHistory | type) // "null"' "$state_file" 2>/dev/null)
        if [ "$hist_type" != "array" ]; then
            passed=false
            append_error "stateHistory 应为数组类型，实际为 $hist_type"
        else
            local hist_len
            hist_len=$(jq '.stateHistory | length' "$state_file" 2>/dev/null || echo "0")
            hist_len=$(echo "$hist_len" | tr -d '[:space:]')
            if [ "${hist_len:-0}" -lt 1 ]; then
                passed=false
                append_error "stateHistory 为空数组，应至少包含 1 条状态转换记录"
            fi

            # 验证每条 stateTransition 的必需字段 + 枚举
            for ((i=0; i<hist_len; i++)); do
                for field in "from" "to" "timestamp" "trigger"; do
                    local has_field
                    has_field=$(jq -r ".stateHistory[$i].$field" "$state_file" 2>/dev/null)
                    if [ "$has_field" = "null" ]; then
                        # 'from' 可以为 null（首次转换），其他字段不行
                        if [ "$field" = "from" ]; then
                            continue
                        fi
                        passed=false
                        append_error "stateHistory[$i]: 缺少必需字段 '$field'"
                    fi
                done

                # 验证 to 枚举
                local to_state
                to_state=$(jq -r ".stateHistory[$i].to // \"\"" "$state_file" 2>/dev/null)
                if [ -n "$to_state" ] && ! value_in_array "$to_state" "${VALID_STATES[@]}"; then
                    passed=false
                    append_error "stateHistory[$i].to 非法枚举值: '$to_state'（预期 S0-S9）"
                fi

                # 验证 from 枚举（可为 null）
                local from_state
                from_state=$(jq -r ".stateHistory[$i].from // \"\"" "$state_file" 2>/dev/null)
                if [ -n "$from_state" ] && [ "$from_state" != "null" ]; then
                    if ! value_in_array "$from_state" "${VALID_STATES[@]}"; then
                        passed=false
                        append_error "stateHistory[$i].from 非法枚举值: '$from_state'（预期 S0-S9 或 null）"
                    fi
                fi

                # 验证 timestamp 格式
                local ts
                ts=$(jq -r ".stateHistory[$i].timestamp // \"\"" "$state_file" 2>/dev/null)
                if [ -n "$ts" ] && [ "$ts" != "null" ]; then
                    if ! is_valid_iso8601 "$ts"; then
                        passed=false
                        append_error "stateHistory[$i].timestamp 不是合法 ISO 8601 日期: '$ts'"
                    fi
                fi

                # 验证 trigger 枚举
                local trig
                trig=$(jq -r ".stateHistory[$i].trigger // \"\"" "$state_file" 2>/dev/null)
                if [ -n "$trig" ] && [ "$trig" != "null" ]; then
                    if ! value_in_array "$trig" "gate-passed" "gate-skipped" "human-override" "agent-handoff" "fallback" "auto-advance"; then
                        append_warning "stateHistory[$i].trigger 非法值: '$trig'（预期 gate-passed/gate-skipped/human-override/agent-handoff/fallback/auto-advance）"
                    fi
                fi
            done
        fi
    else
        # 降级
        if ! grep -q '"stateHistory"' "$state_file" 2>/dev/null; then
            passed=false
            append_error "未找到 stateHistory 字段 [grep 降级校验]"
        elif ! grep -q '"from"' "$state_file" 2>/dev/null || ! grep -q '"to"' "$state_file" 2>/dev/null; then
            passed=false
            append_error "stateHistory 缺少 from/to 字段 [grep 降级校验]"
        fi
        append_warning "jq 不可用，stateHistory 校验降级为 grep（仅检查字段存在性）"
    fi

    append_check "state-history" "$passed"
    $passed
}

# 校验 8：feedbackLoop 结构（若存在）
check_feedback_loop() {
    local state_file="$1"
    local passed=true

    if [ "$HAS_JQ" = true ]; then
        local fl_exists
        fl_exists=$(jq -r 'has("feedbackLoop")' "$state_file" 2>/dev/null)
        if [ "$fl_exists" = "true" ]; then
            # retryCount >= 0
            local rc
            rc=$(jq -r '.feedbackLoop.retryCount // 0' "$state_file" 2>/dev/null)
            rc=$(echo "$rc" | tr -d '[:space:]')
            if [ "${rc:-0}" -lt 0 ]; then
                passed=false
                append_error "feedbackLoop.retryCount = $rc，预期 >= 0"
            fi

            # maxRetries >= 1
            local mr
            mr=$(jq -r '.feedbackLoop.maxRetries // 3' "$state_file" 2>/dev/null)
            mr=$(echo "$mr" | tr -d '[:space:]')
            if [ "${mr:-3}" -lt 1 ]; then
                passed=false
                append_error "feedbackLoop.maxRetries = $mr，预期 >= 1"
            fi

            # 可选：验证 retryCount <= maxRetries（警告，不阻塞）
            if [ "${rc:-0}" -gt "${mr:-3}" ] 2>/dev/null; then
                append_warning "feedbackLoop: retryCount ($rc) 超过 maxRetries ($mr)，可能触发人类 Checkpoint"
            fi

            # 验证 lastFailure 日期格式
            local lf
            lf=$(jq -r '.feedbackLoop.lastFailure // ""' "$state_file" 2>/dev/null)
            if [ -n "$lf" ] && [ "$lf" != "null" ]; then
                if ! is_valid_iso8601 "$lf"; then
                    append_warning "feedbackLoop.lastFailure 不是合法 ISO 8601 日期: '$lf'"
                fi
            fi

            # 验证 lastFailureGate 枚举
            local lfg
            lfg=$(jq -r '.feedbackLoop.lastFailureGate // ""' "$state_file" 2>/dev/null)
            if [ -n "$lfg" ] && [ "$lfg" != "null" ]; then
                if ! value_in_array "$lfg" "gate-1" "gate-2" "gate-3" "gate-4" "gate-5" "gate-6" "gate-7"; then
                    append_warning "feedbackLoop.lastFailureGate 非法值: '$lfg'"
                fi
            fi

            # 验证 stalledSince 日期格式
            local ss
            ss=$(jq -r '.feedbackLoop.stalledSince // ""' "$state_file" 2>/dev/null)
            if [ -n "$ss" ] && [ "$ss" != "null" ]; then
                if ! is_valid_iso8601 "$ss"; then
                    append_warning "feedbackLoop.stalledSince 不是合法 ISO 8601 日期: '$ss'"
                fi
            fi

            # 验证 retryHistory 是数组
            local rh_type
            rh_type=$(jq -r '(.feedbackLoop.retryHistory | type) // "array"' "$state_file" 2>/dev/null)
            if [ "$rh_type" != "array" ]; then
                append_warning "feedbackLoop.retryHistory 应为数组类型（实际为 $rh_type）"
            fi
        fi
    else
        # 降级
        if grep -q '"feedbackLoop"' "$state_file" 2>/dev/null; then
            if ! grep -q '"retryCount"' "$state_file" 2>/dev/null; then
                append_warning "feedbackLoop 存在但缺少 retryCount 字段 [grep 降级校验]"
            fi
            if ! grep -q '"maxRetries"' "$state_file" 2>/dev/null; then
                append_warning "feedbackLoop 存在但缺少 maxRetries 字段 [grep 降级校验]"
            fi
            append_warning "jq 不可用，feedbackLoop 校验降级为 grep（仅检查字段存在性）"
        fi
    fi

    append_check "feedback-loop" "$passed"
    $passed
}

# 校验 9：featureId 格式（kebab-case）
check_feature_id_format() {
    local state_file="$1"
    local passed=true

    if [ "$HAS_JQ" = true ]; then
        local fid
        fid=$(jq -r '.featureId // ""' "$state_file" 2>/dev/null)
        if [ -n "$fid" ]; then
            # 必须是 kebab-case，至少 3 字符
            if ! echo "$fid" | grep -qE '^[a-z0-9][a-z0-9-]{2,63}$'; then
                passed=false
                append_error "featureId 格式非法: '$fid'（预期 kebab-case，至少 3 字符，如 'ai-werewolf'）"
            fi
        fi
    else
        local fid
        fid=$(grep '"featureId"' "$state_file" 2>/dev/null | head -1 \
            | sed 's/.*"featureId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [ -n "$fid" ] && ! echo "$fid" | grep -qE '^[a-z0-9][a-z0-9-]{2,63}$'; then
            passed=false
            append_error "featureId 格式非法: '$fid'（预期 kebab-case，至少 3 字符）[grep 降级校验]"
        fi
    fi

    append_check "feature-id-format" "$passed"
    $passed
}

# 校验 10：互补字段逻辑检查（若 orchestrator=codex 则 challenger 通常为 claude，反之亦然）
check_orchestrator_challenger_consistency() {
    local state_file="$1"
    local passed=true

    if [ "$HAS_JQ" = true ]; then
        local orch
        orch=$(jq -r '.orchestrator // ""' "$state_file" 2>/dev/null)
        local chal
        chal=$(jq -r '.challenger // ""' "$state_file" 2>/dev/null)

        if [ "$orch" = "codex" ] && [ "$chal" = "codex" ]; then
            append_warning "orchestrator 和 challenger 均为 'codex'——缺少独立的挑战者审查"
        elif [ "$orch" = "claude" ] && [ "$chal" = "claude" ]; then
            append_warning "orchestrator 和 challenger 均为 'claude'——缺少独立的挑战者审查"
        elif [ "$orch" = "$chal" ] && [ -n "$orch" ]; then
            append_warning "orchestrator 和 challenger 相同: '$orch'——建议拆分角色"
        fi

        # 若 mode=single-agent 且 challenger 不是 manual/none
        local mode
        mode=$(jq -r '.mode // ""' "$state_file" 2>/dev/null)
        if [ "$mode" = "single-agent" ] && [ "$chal" != "manual" ] && [ "$chal" != "none" ]; then
            append_warning "mode=single-agent 但 challenger='$chal'——建议设为 'manual' 或 'none'"
        fi
    fi

    append_check "orchestrator-challenger-consistency" "$passed"
}

# 校验 11：metadata 推荐字段检查（不阻塞，仅建议）
check_metadata_recommendations() {
    local state_file="$1"

    if [ "$HAS_JQ" = true ]; then
        local has_metadata
        has_metadata=$(jq -r 'has("metadata")' "$state_file" 2>/dev/null)
        if [ "$has_metadata" != "true" ]; then
            append_warning "建议添加 metadata 字段（可包含 repo 路径、相关 issue、tags 等）"
        else
            local has_tags
            has_tags=$(jq -r '(.metadata.tags | type) // "null"' "$state_file" 2>/dev/null)
            if [ "$has_tags" = "array" ]; then
                local tag_count
                tag_count=$(jq '.metadata.tags | length' "$state_file" 2>/dev/null || echo "0")
                tag_count=$(echo "$tag_count" | tr -d '[:space:]')
                if [ "${tag_count:-0}" -eq 0 ]; then
                    append_warning "建议添加 metadata.tags（如 '[\"frontend\",\"api\",\"v1\"]'）"
                fi
            else
                append_warning "建议添加 metadata.tags 数组以改善可发现性"
            fi
        fi
    fi

    append_check "metadata-recommendations" "true"
}

# ---- --fix 模式：自动修正 ------------------------------------------------

# 修正缺失的 createdAt / updatedAt
fix_missing_dates() {
    local state_file="$1"
    local fixed_anything=false

    if [ "$HAS_JQ" != true ]; then
        append_error "--fix 需要 jq，但 jq 不可用"
        return 1
    fi

    local now_iso
    now_iso=$(get_current_utc)

    # 检查 createdAt
    local has_created
    has_created=$(jq -r 'has("createdAt")' "$state_file" 2>/dev/null)
    if [ "$has_created" != "true" ]; then
        jq --arg now "$now_iso" '. + {createdAt: $now}' "$state_file" > "${state_file}.tmp" 2>/dev/null && \
            mv "${state_file}.tmp" "$state_file" && \
            append_autofix "添加缺失的 createdAt: $now_iso" && \
            fixed_anything=true
    fi

    # 检查 updatedAt
    local has_updated
    has_updated=$(jq -r 'has("updatedAt")' "$state_file" 2>/dev/null)
    if [ "$has_updated" != "true" ]; then
        jq --arg now "$now_iso" '. + {updatedAt: $now}' "$state_file" > "${state_file}.tmp" 2>/dev/null && \
            mv "${state_file}.tmp" "$state_file" && \
            append_autofix "添加缺失的 updatedAt: $now_iso" && \
            fixed_anything=true
    fi

    $fixed_anything
}

# 修正空的 stateHistory
fix_empty_state_history() {
    local state_file="$1"
    local fixed_anything=false

    if [ "$HAS_JQ" != true ]; then
        append_error "--fix 需要 jq，但 jq 不可用"
        return 1
    fi

    local hist_len
    hist_len=$(jq '.stateHistory | length' "$state_file" 2>/dev/null || echo "0")
    hist_len=$(echo "$hist_len" | tr -d '[:space:]')

    if [ "${hist_len:-0}" -eq 0 ]; then
        local now_iso
        now_iso=$(get_current_utc)
        local current_state
        current_state=$(jq -r '.currentState // "S0"' "$state_file" 2>/dev/null)
        local orch
        orch=$(jq -r '.orchestrator // "claude"' "$state_file" 2>/dev/null)

        # 构建初始化转换条目
        local init_entry
        init_entry=$(jq -n \
            --arg from null \
            --arg to "$current_state" \
            --arg ts "$now_iso" \
            --arg trig "human-override" \
            --arg actor "$orch" \
            --arg notes "由 validate-state.sh --fix 自动添加初始化转换记录" \
            '{from: $from, to: $to, timestamp: $ts, trigger: $trig, actor: $actor, notes: $notes}' 2>/dev/null)

        if [ -n "$init_entry" ]; then
            jq --argjson entry "$init_entry" '.stateHistory = [$entry]' "$state_file" > "${state_file}.tmp" 2>/dev/null && \
                mv "${state_file}.tmp" "$state_file" && \
                append_autofix "stateHistory 为空，已追加初始化转换记录: null → $current_state" && \
                fixed_anything=true
        fi
    fi

    $fixed_anything
}

# 报告 gates 数组长度不对（不修复，需人类判断）
report_gates_length_issue() {
    local state_file="$1"

    if [ "$HAS_JQ" != true ]; then
        return 1
    fi

    local gate_count
    gate_count=$(jq '.gates | length' "$state_file" 2>/dev/null || echo "0")
    gate_count=$(echo "$gate_count" | tr -d '[:space:]')

    if [ "${gate_count:-0}" -ne 7 ]; then
        append_autofix "gates 数组长度为 $gate_count（预期 7），需要人类判断——未自动修复。请检查门禁定义后手动调整。"
        return 0
    fi
    return 1
}

# 执行所有自动修正
apply_fixes() {
    local state_file="$1"
    local fix_applied=false

    if fix_missing_dates "$state_file"; then
        fix_applied=true
    fi

    if fix_empty_state_history "$state_file"; then
        fix_applied=true
    fi

    report_gates_length_issue "$state_file"

    if [ "$fix_applied" = true ]; then
        # 更新 updatedAt 为当前时间（如果之前没改）
        local now_iso
        now_iso=$(get_current_utc)
        jq --arg now "$now_iso" '.updatedAt = $now' "$state_file" > "${state_file}.tmp" 2>/dev/null && \
            mv "${state_file}.tmp" "$state_file"
    fi
}

# ---- 输出函数 ---------------------------------------------------------------

output_result() {
    local feature_id="$1"
    local errors_json="[${ERRORS_ARRAY}]"
    local warnings_json="[${WARNINGS_ARRAY}]"
    local autofix_json="[${AUTOFIX_ARRAY}]"
    local checks_json="[${CHECKS_ARRAY}]"
    local jq_avail="false"
    [ "$HAS_JQ" = true ] && jq_avail="true"

    cat <<EOF
{
  "featureId": "$(json_escape "$feature_id")",
  "schemaValid": $SCHEMA_VALID,
  "fixMode": $FIX_MODE,
  "checkedAt": "$(get_current_utc)",
  "checks": $checks_json,
  "errors": $errors_json,
  "warnings": $warnings_json,
  "autoFixed": $autofix_json,
  "meta": {
    "script": "$SCRIPT_NAME",
    "jqAvailable": $jq_avail,
    "schemaRef": "workflow/feature-state.schema.json"
  }
}
EOF
}

# ---- 主入口 ----------------------------------------------------------------

main() {
    local feature_id=""

    # ---- 参数解析 ----
    for arg in "$@"; do
        case "$arg" in
            --json)
                JSON_MODE=true
                ;;
            --fix)
                FIX_MODE=true
                ;;
            --help|-h)
                cat <<HELP
用法: $SCRIPT_NAME <feature-id> [--json] [--fix]

参数:
  feature-id      功能目录名（位于 $FEATURES_DIR/<feature-id>/）
  --json          增强 JSON 输出（默认即为 JSON 格式）
  --fix           自动修正可修复的结构问题

退出码:
  0 — Schema 校验全部通过
  1 — 存在校验错误
  2 — 脚本参数错误
  3 — 文件不存在

示例:
  $SCRIPT_NAME ai-werewolf              # 校验 feature-state.json
  $SCRIPT_NAME ai-werewolf --json       # 同默认模式，JSON 输出
  $SCRIPT_NAME ai-werewolf --fix        # 校验并自动修正

校验项一览:
  1. JSON 可解析（jq empty 或 python -m json.tool）
  2. 必需字段存在（featureId, currentState, orchestrator, challenger, mode,
     createdAt, updatedAt, gates, stateHistory）
  3. currentState 合法枚举值（S0-S9）
  4. orchestrator 是 codex|claude
  5. mode 是 dual-agent|single-agent
  6. gates 数组长度 == 7
  7. 每个 gate 有 gateId, status, artifacts
  8. 日期字段是合法 ISO 8601
  9. stateHistory 非空数组
  10. feedbackLoop 若存在，retryCount >= 0, maxRetries >= 1

--fix 自动修正:
  - 缺失 createdAt → 设为当前时间
  - 缺失 updatedAt → 设为当前时间
  - stateHistory 为空 → 追加初始化条目
  - gates 数组长度不对 → 报告但不修复（需要人类判断）

与 gate-check.sh --schema-only 的区别:
  - gate-check.sh --schema-only 是门禁检查的子模式，侧重门禁上下文
  - validate-state.sh 专门做 Schema 校验，粒度更细，校验项更多（10+ 项），
    支持 --fix 自动修正
HELP
                exit 0
                ;;
            -*)
                echo "{\"error\":\"未知标志: '$arg'。使用 --help 查看用法。\"}" >&2
                exit 2
                ;;
            *)
                if [ -z "$feature_id" ]; then
                    feature_id="$arg"
                fi
                ;;
        esac
    done

    # ---- 参数校验 ----
    if [ -z "$feature_id" ]; then
        cat >&2 <<EOF
用法: $SCRIPT_NAME <feature-id> [--json] [--fix]

错误: 缺少必需参数 <feature-id>
使用 --help 查看详细用法。
EOF
        exit 2
    fi

    local feature_dir="$FEATURES_DIR/$feature_id"
    local state_file="$feature_dir/feature-state.json"

    # ---- 目录存在性 ----
    if [ ! -d "$feature_dir" ]; then
        cat <<EOF
{
  "featureId": "$(json_escape "$feature_id")",
  "schemaValid": false,
  "checks": [{"check": "directory-exists", "passed": false}],
  "errors": ["功能目录不存在: $feature_dir"],
  "warnings": ["请先创建功能目录: mkdir -p $FEATURES_DIR/$feature_id"],
  "autoFixed": [],
  "meta": {
    "script": "$SCRIPT_NAME",
    "jqAvailable": $HAS_JQ
  }
}
EOF
        exit 3
    fi

    # ---- 文件存在性 ----
    if [ ! -f "$state_file" ]; then
        cat <<EOF
{
  "featureId": "$(json_escape "$feature_id")",
  "schemaValid": false,
  "checks": [{"check": "file-exists", "passed": false}],
  "errors": ["feature-state.json 不存在: $state_file"],
  "warnings": ["请先创建 feature-state.json（可参考 workflow/feature-state.schema.json 中的 examples）"],
  "autoFixed": [],
  "meta": {
    "script": "$SCRIPT_NAME",
    "jqAvailable": $HAS_JQ
  }
}
EOF
        exit 3
    fi

    # ---- --fix 模式：先修正再校验 ----
    if [ "$FIX_MODE" = true ]; then
        if [ "$HAS_JQ" != true ]; then
            append_error "--fix 模式需要 jq，但当前环境未安装 jq。请安装 jq 或使用 package manager 安装。"
            output_result "$feature_id"
            exit 1
        fi

        # 备份原文件
        cp "$state_file" "${state_file}.bak" 2>/dev/null

        apply_fixes "$state_file"

        # 若没有修改，清理备份
        if [ "$FIX_COUNT" -eq 0 ]; then
            rm -f "${state_file}.bak" 2>/dev/null
        fi
    fi

    # ---- 执行校验 ----
    # 校验顺序：从基础到深入，尽早失败

    # 1. JSON 可解析（必须先通过，否则后续校验无意义）
    if ! check_json_parseable "$state_file"; then
        # JSON 不可解析，跳过后续所有校验
        output_result "$feature_id"
        exit 1
    fi

    # 2. 必需字段
    check_required_fields "$state_file"

    # 3. featureId 格式
    check_feature_id_format "$state_file"

    # 4. 枚举值
    check_enum_values "$state_file"

    # 5. 日期格式
    check_date_format "$state_file"

    # 6. gates 数量
    check_gates_count "$state_file"

    # 7. gate 结构
    check_gate_structure "$state_file"

    # 8. stateHistory
    check_state_history "$state_file"

    # 9. feedbackLoop
    check_feedback_loop "$state_file"

    # 10. orchestrator/challenger 一致性（警告级）
    check_orchestrator_challenger_consistency "$state_file"

    # 11. metadata 建议（警告级）
    check_metadata_recommendations "$state_file"

    # 全局建议（不绑定特定校验项）
    if [ "$HAS_JQ" != true ]; then
        append_warning "jq 不可用，多项校验已降级为 grep，建议安装 jq 以获得完整校验能力"
    fi

    # ---- 输出结果 ----
    output_result "$feature_id"

    if [ "$SCHEMA_VALID" = true ]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
