#!/usr/bin/env bash
# ============================================================================
# gate-check.sh — 确定性门禁检查脚本（零 LLM 调用）
# ============================================================================
# 设计原则：
#   1. 零 LLM 调用——纯文件系统 + 文本模式匹配
#   2. fail-closed——任何不确定状态 → 返回非零
#   3. 文件系统是唯一真相源——产物文件在不在比任何元数据字段都可靠
#   4. 纯 shell，兼容 Git Bash on Windows——无 python 依赖，jq 可选
#   5. 输出格式：每门禁一个 JSON 对象 {gate, status, missing, warnings}
#
# 用法：
#   bash workflow/scripts/gate-check.sh <feature-id> [target-gate] [flags]
#
# 参数：
#   feature-id      必需。功能目录名（位于 workflow/features/<feature-id>/）
#   target-gate     可选。目标门禁编号 G1-G7，或 "all"（默认检查全部已到达门禁）
#                   也接受 gate-1..gate-7 或纯数字 1..7
#   --enforce       强制执行模式：若 fail，输出阻止指令 JSON 并退出非零
#   --schema-only   仅校验 feature-state.json 结构，不检查门禁产物
#   --json          增强 JSON 输出，添加 machine-readable 字段供 dispatch.sh 解析
#
# 退出码：
#   0 — 所有检查通过 / --schema-only 校验通过
#   1 — 存在失败项 / --enforce 阻止
#   2 — 脚本自身错误（如参数错误、目录不存在）
#
# ============================================================================
# dispatch.sh 调用说明：
# ============================================================================
# dispatch.sh 通过两种方式调用本脚本：
#
# 1. 普通检查（状态转换前）：
#      result=$(bash workflow/scripts/gate-check.sh <feature-id> --json)
#      decision=$(echo "$result" | jq -r '.decision')
#      if [ "$decision" = "proceed" ]; then
#          # 允许状态转换：更新 feature-state.json，推进到下一状态
#      else
#          # 阻止转换：failedGate / failedReason 指明原因
#      fi
#
# 2. 强制执行（CI / pre-commit hook）：
#      bash workflow/scripts/gate-check.sh <feature-id> --enforce
#      if [ $? -ne 0 ]; then
#          # 解析 JSON 获取 rollbackTo / requiredAction
#          # 阻止 commit 或 CI pipeline 继续
#      fi
#
# 3. Schema 校验：
#      bash workflow/scripts/gate-check.sh <feature-id> --schema-only
#      # 输出 { "schemaValid": true/false, "errors": [...] }
# ============================================================================

set -o pipefail

# ---- 路径配置 ---------------------------------------------------------------
FEATURES_DIR="${WORKFLOW_FEATURES_DIR:-workflow/features}"
SCRIPT_NAME="${0##*/}"

# ---- 版本信息（供 dispatch.sh 兼容性检查） -----------------------------------
SCRIPT_VERSION="2.0.0"
OUTPUT_FORMAT="gate-check-v2"

# ---- 工具检测 ---------------------------------------------------------------
HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
    HAS_JQ=true
fi

# ---- 全局状态 ---------------------------------------------------------------
EXIT_CODE=0
RESULTS_JSON=""          # 累积每个门禁的 JSON 对象
RESULT_COUNT=0
WARNINGS_GLOBAL=""       # 全局警告（不影响 pass/fail）
FIRST_FAILED_GATE=""     # 第一个失败的门禁编号（供 --enforce / --json 使用）
FIRST_FAILED_REASON=""   # 第一个失败的原因描述

# ---- 模式标志 ---------------------------------------------------------------
ENFORCE_MODE=false
SCHEMA_ONLY_MODE=false
JSON_MODE=false

# ---- 门禁 → 回退状态映射（供 --enforce 使用）-------------------------------
declare -A GATE_ROLLBACK
GATE_ROLLBACK["G1"]="S2"
GATE_ROLLBACK["G2"]="S3"
GATE_ROLLBACK["G3"]="S4"
GATE_ROLLBACK["G4"]="S5"
GATE_ROLLBACK["G5"]="S6"
GATE_ROLLBACK["G6"]="S7"
GATE_ROLLBACK["G7"]="S8"

# ---- 门禁 → 失败原因描述（供 --enforce / --json 使用）-----------------------
declare -A GATE_FAIL_REASON
GATE_FAIL_REASON["G1"]="Gate 1 失败: 01-openspec-proposal.md 缺失或内容不完整"
GATE_FAIL_REASON["G2"]="Gate 2 失败: 02-grill-me-report.md 缺失或风险未记录"
GATE_FAIL_REASON["G3"]="Gate 3 失败: 03-task-skill-map.md 缺失或任务未路由"
GATE_FAIL_REASON["G4"]="Gate 4 失败: 04-implementation-plan.md 缺失"
GATE_FAIL_REASON["G5"]="Gate 5 失败: reviews/ 目录缺失或审查报告不完整"
GATE_FAIL_REASON["G6"]="Gate 6 失败: 05-verification-log.md 缺失或验证不完整"
GATE_FAIL_REASON["G7"]="Gate 7 失败: 06-adr.md 或 07-task-retro.md 缺失"

# ---- 门禁 → 补救动作描述（供 --enforce 使用）--------------------------------
declare -A GATE_ACTION
GATE_ACTION["G1"]="回退到 S2，编写完整的 OpenSpec 提案后重试"
GATE_ACTION["G2"]="回退到 S3，完成 grill-me 风险审查后重试"
GATE_ACTION["G3"]="回退到 S4，填写任务-技能映射表后重试"
GATE_ACTION["G4"]="回退到 S5，补充 implementation-plan.md 后重试"
GATE_ACTION["G5"]="回退到 S6，完成审查报告后重试"
GATE_ACTION["G6"]="回退到 S7，完成验证并记录结果后重试"
GATE_ACTION["G7"]="回退到 S8，完成 ADR 和任务回顾后重试"

# ---- 辅助函数 ---------------------------------------------------------------

# JSON 字符串转义（纯 sed，无外部依赖）
#   转义 \ " 以及控制字符
json_escape() {
    local input="$1"
    # 先转义反斜杠，再转义双引号，再处理换行/回车/制表符
    printf '%s' "$input" \
        | sed 's/\\/\\\\/g' \
        | sed 's/"/\\"/g' \
        | sed 's/\x09/\\t/g' \
        | sed 's/\x0D//g' \
        | sed ':a;N;$!ba;s/\n/\\n/g'
}

# 构建 JSON 字符串数组 ["a","b"]
json_str_array() {
    local first=true
    local out="["
    for item in "$@"; do
        if [ "$first" = true ]; then first=false; else out+=","; fi
        local escaped
        escaped=$(json_escape "$item")
        out+="\"$escaped\""
    done
    out+="]"
    printf '%s' "$out"
}

# 追加一条门禁结果
append_gate_result() {
    local gate="$1"
    local status="$2"
    shift 2
    local missing=()
    local warnings=()
    local collecting="missing"

    # 解析参数：--warnings 之后的内容算 warnings
    for arg in "$@"; do
        if [ "$arg" = "--warnings" ]; then
            collecting="warnings"
            continue
        fi
        if [ "$collecting" = "missing" ]; then
            missing+=("$arg")
        else
            warnings+=("$arg")
        fi
    done

    local missing_json
    missing_json=$(json_str_array "${missing[@]}")
    local warnings_json
    warnings_json=$(json_str_array "${warnings[@]}")

    local gate_obj
    gate_obj="{\"gate\":\"$gate\",\"status\":\"$status\",\"missing\":$missing_json,\"warnings\":$warnings_json}"

    if [ $RESULT_COUNT -gt 0 ]; then
        RESULTS_JSON+=","
    fi
    RESULTS_JSON+="
    $gate_obj"
    RESULT_COUNT=$((RESULT_COUNT + 1))

    # 追踪第一个失败的门禁（供 --enforce / --json 使用）
    if [ "$status" = "fail" ] && [ -z "$FIRST_FAILED_GATE" ]; then
        FIRST_FAILED_GATE="$gate"
        # 从 missing 数组提取第一条作为原因缩略
        if [ ${#missing[@]} -gt 0 ]; then
            FIRST_FAILED_REASON="${GATE_FAIL_REASON[$gate]}"
        else
            FIRST_FAILED_REASON="${GATE_FAIL_REASON[$gate]}"
        fi
    fi
}

# 标准化门禁编号：将各种输入格式统一为 "G1".."G7"
normalize_gate() {
    local raw="$1"
    case "$raw" in
        all|ALL|"") echo "G7" ;;           # 默认检查到 G7
        G[1-7]|g[1-7]) echo "${raw^^}" ;;  # G1..G7 → 保持
        gate-[1-7]|GATE-[1-7]) echo "G${raw: -1}" ;; # gate-1 → G1
        [1-7]) echo "G$raw" ;;             # 1 → G1
        *) echo "" ;;                      # 无效
    esac
}

# 检查文件是否存在且不小于最小字节数
# 返回：0 = 存在且足够大，1 = 缺失，2 = 太小
check_file() {
    local full_path="$1"
    local min_bytes="${2:-1}"
    local label="${3:-$full_path}"

    if [ ! -e "$full_path" ]; then
        return 1  # missing
    fi
    if [ ! -f "$full_path" ]; then
        return 1  # not a regular file
    fi
    local size
    size=$(wc -c < "$full_path" 2>/dev/null || echo "0")
    size=$(echo "$size" | tr -d '[:space:]')
    if [ "${size:-0}" -lt "$min_bytes" ]; then
        return 2  # too small
    fi
    return 0  # ok
}

# 检查 Markdown 文件头部是否包含指定模式（零依赖，bash 内置）
# 每个模式是空格分隔的多个子串，任一子串匹配即通过（OR 逻辑）
# 返回：0 = 所有模式组均匹配，1 = 至少一组未匹配
check_content_patterns() {
    local file="$1"
    shift
    local pattern_groups=("$@")
    local missing_count=0

    # 只搜索文件头部 100 行（避免扫描整个大文件）
    local head_content
    head_content=$(head -100 "$file" 2>/dev/null)

    for group_spec in "${pattern_groups[@]}"; do
        local matched=false
        # 组内用 | 分隔多个候选子串（纯 bash 字符串匹配，grep -F 精确匹配）
        IFS='|' read -ra candidates <<< "$group_spec"
        for candidate in "${candidates[@]}"; do
            if echo "$head_content" | grep -qF "$candidate" 2>/dev/null; then
                matched=true
                break
            fi
        done
        if [ "$matched" = false ]; then
            missing_count=$((missing_count + 1))
        fi
    done
    return $missing_count
}

# 大小写不敏感的 grep -qF 安全替代
# grep -i 在某些 Windows Git Bash 上会崩溃（exit 134），
# 此函数通过 tr 转小写后 grep -qF 实现等价功能
safe_igrep() {
    local pattern="$1"
    tr '[:upper:]' '[:lower:]' | grep -qF "$pattern" 2>/dev/null
}

# 统计目录下匹配 glob 的文件数
count_files_in_dir() {
    local dir="$1"
    local glob="${2:-*.md}"
    local count
    count=$(find "$dir" -maxdepth 1 -name "$glob" -type f 2>/dev/null | wc -l)
    echo "$count" | tr -d '[:space:]'
}

# 尝试读取 feature-state.json 中的 currentState 字段（使用 grep+sed，零依赖，兼容 Git Bash）
read_feature_state() {
    local state_file="$1"
    if [ ! -f "$state_file" ]; then
        echo "S0"
        return
    fi
    # 从 JSON 中用基本 grep 提取 currentState。
    # 支持 "currentState": "S3" 和 "currentState":"S3" 两种写法
    local state
    state=$(grep '"currentState"' "$state_file" 2>/dev/null \
        | head -1 \
        | sed 's/.*"currentState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    if [ -z "$state" ] || [ "$state" = "$(head -1 "$state_file" 2>/dev/null)" ]; then
        echo "S0"
    else
        echo "$state"
    fi
}

# 尝试读取 feature-state.json 中的 mode 字段（dual-agent / single-agent）
read_feature_mode() {
    local state_file="$1"
    if [ ! -f "$state_file" ]; then
        echo "dual-agent"
        return
    fi
    local mode
    mode=$(grep '"mode"' "$state_file" 2>/dev/null \
        | head -1 \
        | sed 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    if [ -z "$mode" ] || [ "$mode" = "$(head -1 "$state_file" 2>/dev/null)" ]; then
        echo "dual-agent"
    else
        echo "$mode"
    fi
}

# ---- 可选：feature-state.json 结构校验（使用 jq 或 grep 降级）--------------
#
# 说明：本函数用于普通门禁检查中的 schema 旁路警告。
#       --schema-only 模式使用独立的 schema_only_check() 函数，
#       输出格式为 { "schemaValid": true/false, "errors": [...] }。

validate_state_json() {
    local state_file="$1"
    local warnings=()
    local errors=()

    # 文件存在性
    if [ ! -f "$state_file" ]; then
        # 这不是错误——feature-state.json 是可选的加速器，产物文件才是权威
        warnings+=("feature-state.json 不存在（非阻塞，产物文件检查仍是权威来源）")
        printf '%s\n' "${warnings[@]}"
        return 0
    fi

    if [ "$HAS_JQ" = true ]; then
        # ---- jq 路径：完整 JSON 结构校验 ----
        if ! jq empty "$state_file" 2>/dev/null; then
            errors+=("feature-state.json: JSON 语法错误")
        else
            # 检查必需顶层字段
            for field in "featureId" "currentState" "orchestrator" "mode" "gates" "stateHistory"; do
                if jq -e ".$field" "$state_file" >/dev/null 2>&1; then
                    : # ok
                else
                    warnings+=("feature-state.json: 缺少推荐字段 '$field'")
                fi
            done

            # 检查 currentState 是否为有效枚举值
            local state
            state=$(jq -r '.currentState // ""' "$state_file" 2>/dev/null)
            case "$state" in
                S0|S1|S2|S3|S4|S5|S6|S7|S8|S9) : ;; # valid
                "") warnings+=("feature-state.json: currentState 为空") ;;
                *)  warnings+=("feature-state.json: currentState='$state' 非标准状态值") ;;
            esac

            # 检查 orchestrator
            local orch
            orch=$(jq -r '.orchestrator // ""' "$state_file" 2>/dev/null)
            case "$orch" in
                codex|claude) : ;;
                "") warnings+=("feature-state.json: orchestrator 为空") ;;
                *)  warnings+=("feature-state.json: orchestrator='$orch' 非标准值") ;;
            esac

            # 检查 mode
            local mode
            mode=$(jq -r '.mode // ""' "$state_file" 2>/dev/null)
            case "$mode" in
                dual-agent|single-agent) : ;;
                "") warnings+=("feature-state.json: mode 为空") ;;
                *)  warnings+=("feature-state.json: mode='$mode' 非标准值") ;;
            esac

            # 检查 gates 数组长度
            local gate_count
            gate_count=$(jq '.gates | length' "$state_file" 2>/dev/null || echo "0")
            if [ "${gate_count:-0}" -ne 7 ]; then
                warnings+=("feature-state.json: gates 数组长度为 $gate_count，预期 7")
            fi
        fi
    else
        # ---- 降级路径：grep 基础校验 ----
        # 检查 JSON 是否至少以 { 开头
        local first_char
        first_char=$(head -c 1 "$state_file" 2>/dev/null | tr -d '[:space:]')
        if [ "$first_char" != "{" ] && [ "$first_char" != "[" ]; then
            warnings+=("feature-state.json: 文件不以 JSON 对象或数组开头，可能非 JSON 格式")
        fi

        # 检查关键字段是否存在
        for field in "featureId" "currentState" "gates"; do
            if ! grep -q "\"$field\"" "$state_file" 2>/dev/null; then
                warnings+=("feature-state.json: 未找到推荐字段 '$field'")
            fi
        done
    fi

    # 输出所有发现
    for e in "${errors[@]}"; do
        echo "ERROR: $e" >&2
    done
    for w in "${warnings[@]}"; do
        echo "$w"
    done

    if [ ${#errors[@]} -gt 0 ]; then
        return 1
    fi
    return 0
}

# ---- --schema-only：独立 Schema 校验函数 ------------------------------------
#
# 校验 feature-state.json 是否符合 feature-state.schema.json。
# 使用 jq（若可用）或 grep 降级。
# 输出格式：
#   { "schemaValid": true/false, "errors": ["err1","err2",...] }
# 退出码：0 = 校验通过，1 = 存在错误，2 = 文件不存在

schema_only_check() {
    local state_file="$1"
    local errors=()
    local schema_valid=true

    # 文件不存在即失败
    if [ ! -f "$state_file" ]; then
        cat <<EOF
{
  "schemaValid": false,
  "errors": ["feature-state.json 不存在"],
  "checkedFields": ["featureId","currentState","orchestrator","mode","gates","stateHistory"],
  "gatesExpected": 7,
  "validStates": ["S0","S1","S2","S3","S4","S5","S6","S7","S8","S9"],
  "validOrchestrators": ["codex","claude"],
  "validModes": ["dual-agent","single-agent"]
}
EOF
        return 2
    fi

    # 解析器选择
    if [ "$HAS_JQ" = true ]; then
        # ---- jq 路径：完整结构校验 ----

        # JSON 语法校验
        if ! jq empty "$state_file" 2>/dev/null; then
            errors+=("JSON 语法错误：文件无法被 jq 解析")
            schema_valid=false
        else
            # 1) 检查 required 顶层字段
            local required_fields=("featureId" "currentState" "orchestrator" "mode" "gates" "stateHistory")
            for field in "${required_fields[@]}"; do
                if ! jq -e ".$field" "$state_file" >/dev/null 2>&1; then
                    errors+=("缺少必需字段: '$field'")
                    schema_valid=false
                fi
            done

            # 2) 检查 currentState 枚举值
            local state
            state=$(jq -r '.currentState // ""' "$state_file" 2>/dev/null)
            if [ -n "$state" ]; then
                case "$state" in
                    S0|S1|S2|S3|S4|S5|S6|S7|S8|S9) : ;;
                    *) errors+=("currentState 非法枚举值: '$state'（预期 S0-S9）")
                       schema_valid=false ;;
                esac
            fi

            # 3) 检查 orchestrator 枚举值
            local orch
            orch=$(jq -r '.orchestrator // ""' "$state_file" 2>/dev/null)
            if [ -n "$orch" ]; then
                case "$orch" in
                    codex|claude) : ;;
                    *) errors+=("orchestrator 非法枚举值: '$orch'（预期 codex 或 claude）")
                       schema_valid=false ;;
                esac
            fi

            # 4) 检查 mode 枚举值
            local mode
            mode=$(jq -r '.mode // ""' "$state_file" 2>/dev/null)
            if [ -n "$mode" ]; then
                case "$mode" in
                    dual-agent|single-agent) : ;;
                    *) errors+=("mode 非法枚举值: '$mode'（预期 dual-agent 或 single-agent）")
                       schema_valid=false ;;
                esac
            fi

            # 5) 检查 gates 数组长度 == 7
            local gate_count
            gate_count=$(jq '.gates | length' "$state_file" 2>/dev/null || echo "0")
            if [ "${gate_count:-0}" -ne 7 ]; then
                errors+=("gates 数组长度为 $gate_count，预期 7")
                schema_valid=false
            fi

            # 6) 检查 stateHistory 是否为数组
            local hist_type
            hist_type=$(jq -r '(.stateHistory | type) // "null"' "$state_file" 2>/dev/null)
            if [ "$hist_type" != "array" ]; then
                errors+=("stateHistory 应为数组类型，实际为 $hist_type")
                schema_valid=false
            fi
        fi
    else
        # ---- 降级路径：grep 基础校验 ----
        # 检查 JSON 是否以 { 开头
        local first_char
        first_char=$(head -c 1 "$state_file" 2>/dev/null | tr -d '[:space:]')
        if [ "$first_char" != "{" ]; then
            errors+=("文件不以 JSON 对象开头，可能非合法 JSON")
            schema_valid=false
        fi

        # 检查 required 字段
        local required_fields=("featureId" "currentState" "orchestrator" "mode" "gates" "stateHistory")
        for field in "${required_fields[@]}"; do
            if ! grep -q "\"$field\"" "$state_file" 2>/dev/null; then
                errors+=("缺少必需字段: '$field'（grep 降级校验，精度有限）")
                schema_valid=false
            fi
        done

        # 检查 currentState 枚举（grep 提取后校验）
        local state
        state=$(grep '"currentState"' "$state_file" 2>/dev/null \
            | head -1 \
            | sed 's/.*"currentState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [ -n "$state" ]; then
            case "$state" in
                S0|S1|S2|S3|S4|S5|S6|S7|S8|S9) : ;;
                *) errors+=("currentState 非法值: '$state'（预期 S0-S9）")
                   schema_valid=false ;;
            esac
        fi

        # 检查 gates 数组长度（grep 计数）
        local gate_count
        gate_count=$(grep -c '"gate"' "$state_file" 2>/dev/null || echo "0")
        gate_count=$(echo "$gate_count" | tr -d '[:space:]')
        if [ "${gate_count:-0}" -ne 7 ] && [ "${gate_count:-0}" -ne 0 ]; then
            errors+=("gates 条目数约为 $gate_count，预期 7（grep 降级校验，精度有限）")
            schema_valid=false
        fi

        # jq 不可用时标注
        errors+=("警告: jq 不可用，已降级为 grep 基础校验（精度有限）")
    fi

    # 输出结果
    local errors_json
    errors_json=$(json_str_array "${errors[@]}")

    cat <<EOF
{
  "schemaValid": $schema_valid,
  "errors": $errors_json,
  "checkedFields": ["featureId","currentState","orchestrator","mode","gates","stateHistory"],
  "gatesExpected": 7,
  "validStates": ["S0","S1","S2","S3","S4","S5","S6","S7","S8","S9"],
  "validOrchestrators": ["codex","claude"],
  "validModes": ["dual-agent","single-agent"],
  "jqAvailable": $HAS_JQ
}
EOF

    if [ "$schema_valid" = true ]; then
        return 0
    else
        return 1
    fi
}

# ---- --enforce：输出阻止指令 JSON --------------------------------------------
#
# 当门禁检查有失败项时，输出阻止指令供 CI / pre-commit hook 消费。
# 退出码：1（阻止）

output_enforce_blocked() {
    local failed_gate="$1"
    local total_passed="$2"
    local total_failed="$3"
    local reason="${GATE_FAIL_REASON[$failed_gate]}"
    local action="${GATE_ACTION[$failed_gate]}"
    local rollback="${GATE_ROLLBACK[$failed_gate]}"

    cat <<EOF
{
  "enforce": true,
  "blocked": true,
  "reason": "$reason",
  "requiredAction": "$action",
  "rollbackTo": "$rollback",
  "humanCheckpointTriggered": false,
  "failedGate": "$failed_gate",
  "gateSummary": {
    "checkAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)",
    "featureId": "$FEATURE_ID",
    "targetGate": "$TARGET_GATE",
    "totalChecked": $RESULT_COUNT,
    "passed": $total_passed,
    "failed": $total_failed
  }
}
EOF
    exit 1
}

# 当 --enforce 模式下所有门禁通过时输出
output_enforce_pass() {
    cat <<EOF
{
  "enforce": true,
  "blocked": false,
  "reason": "",
  "requiredAction": "",
  "rollbackTo": "",
  "humanCheckpointTriggered": false,
  "gateSummary": {
    "checkAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)",
    "featureId": "$FEATURE_ID",
    "targetGate": "$TARGET_GATE",
    "totalChecked": $RESULT_COUNT,
    "passed": $RESULT_COUNT,
    "failed": 0
  }
}
EOF
    exit 0
}

# ---- 门禁产物定义 -----------------------------------------------------------
# 每个门禁定义包含：
#   1. 必需文件（路径:最小字节数:描述标签）
#   2. 可选内容模式检查（文件:grep模式:警告说明）

declare -A GATE_LABEL
GATE_LABEL["G1"]="规格就绪 (Spec Ready)"
GATE_LABEL["G2"]="风险就绪 (Risk Ready)"
GATE_LABEL["G3"]="任务就绪 (Task Ready)"
GATE_LABEL["G4"]="实现就绪 (Implementation Ready)"
GATE_LABEL["G5"]="审查就绪 (Review Ready)"
GATE_LABEL["G6"]="已验证 (Verified)"
GATE_LABEL["G7"]="知识已捕获 (Knowledge Captured)"

# ---- G1: 规格就绪 -----------------------------------------------------------
# 参考 AGENTS.md 门禁 1：
#   - 提案包含目标、非目标、用户、核心流程、数据/API 契约、验收标准、明确的不在范围内事项
#   - 全新功能需人类已审查并批准提案中的关键设计决策（脚本无法验证此过程条件）
check_gate_g1() {
    local feature_dir="$1"
    local missing=()
    local warnings=()

    # 必需产物
    local proposal="$feature_dir/01-openspec-proposal.md"
    check_file "$proposal" 300 "01-openspec-proposal.md"
    local rc=$?
    case $rc in
        1) missing+=("01-openspec-proposal.md（文件不存在）") ;;
        2) warnings+=("01-openspec-proposal.md 文件过小（<300 bytes），可能为空白模板") ;;
    esac

    # 内容模式检查：提案必须涵盖的关键章节
    # 使用 grep -F（固定字符串匹配），兼容 Git Bash 且不受 locale 影响
    # 每项检查含英文和中文候选词，任一命中即通过
    if [ -f "$proposal" ]; then
        local head_data
        head_data=$(head -100 "$proposal" 2>/dev/null)

        # 检查「目标」
        if ! echo "$head_data" | grep -qF "目标" && ! echo "$head_data" | safe_igrep "goal"; then
            warnings+=("提案中未找到「目标」章节")
        fi

        # 检查「非目标」
        if ! echo "$head_data" | grep -qF "非目标" && ! echo "$head_data" | safe_igrep "non-goal"; then
            warnings+=("提案中未找到「非目标」章节")
        fi

        # 检查「验收标准」
        if ! echo "$head_data" | grep -qF "验收" && ! echo "$head_data" | safe_igrep "acceptance"; then
            warnings+=("提案中未找到「验收标准」章节")
        fi

        # 检查「用户与角色」
        if ! echo "$head_data" | grep -qF "用户" && ! echo "$head_data" | safe_igrep "user"; then
            warnings+=("提案中未找到「用户与角色」章节")
        fi

        # 检查「决策日志」（全新功能需要）——脚本无法判断是否为全新功能，降级为提示
        if ! echo "$head_data" | grep -qF "决策日志" && ! echo "$head_data" | safe_igrep "decision log" && ! echo "$head_data" | safe_igrep "decision"; then
            warnings+=("提案缺少「决策日志」章节——全新功能需人类审批记录")
        fi
    fi

    local status="pass"
    [ ${#missing[@]} -gt 0 ] && status="fail"

    append_gate_result "G1" "$status" "${missing[@]}" --warnings "${warnings[@]}"
}

# ---- G2: 风险就绪 -----------------------------------------------------------
# 参考 AGENTS.md 门禁 2：
#   - grill-me 报告已被答复，或每个未解决的风险都标记为已接受并注明负责人和日期
#   - grill-me 是 Agent 领地（技术风险），不重新审视设计决策
check_gate_g2() {
    local feature_dir="$1"
    local missing=()
    local warnings=()

    local grill="$feature_dir/02-grill-me-report.md"
    check_file "$grill" 200 "02-grill-me-report.md"
    local rc=$?
    case $rc in
        1) missing+=("02-grill-me-report.md（文件不存在）") ;;
        2) warnings+=("02-grill-me-report.md 文件过小（<200 bytes），可能为空白模板") ;;
    esac

    if [ -f "$grill" ]; then
        local head_data
        head_data=$(head -100 "$grill" 2>/dev/null)

        # 必须包含风险发现表格或 P0/P1 引用
        if ! echo "$head_data" | grep -qF "P0" && ! echo "$head_data" | grep -qF "P1" \
            && ! echo "$head_data" | safe_igrep "finding" && ! echo "$head_data" | grep -qF "风险" \
            && ! echo "$head_data" | safe_igrep "severity"; then
            warnings+=("grill-me 报告未找到风险发现（Finding/风险/P0/P1）相关内容")
        fi

        # 检查是否有 Accepted Residual Risks 章节
        if ! echo "$head_data" | safe_igrep "accepted" && ! echo "$head_data" | safe_igrep "residual" \
            && ! echo "$head_data" | grep -qF "接受" && ! echo "$head_data" | grep -qF "残留"; then
            warnings+=("grill-me 报告缺少「已接受的残留风险」章节——未解决风险需明确记录")
        fi

        # 检查 grill-me 来源标注
        if ! echo "$head_data" | safe_igrep "source:" && ! echo "$head_data" | grep -qF "来源" \
            && ! echo "$head_data" | safe_igrep "grill-me" && ! echo "$head_data" | safe_igrep "manual-grill"; then
            warnings+=("grill-me 报告缺少来源标注（Source 字段）——需标明 codex/claude/manual")
        fi
    fi

    local status="pass"
    [ ${#missing[@]} -gt 0 ] && status="fail"

    append_gate_result "G2" "$status" "${missing[@]}" --warnings "${warnings[@]}"
}

# ---- G3: 任务就绪 -----------------------------------------------------------
# 参考 AGENTS.md 门禁 3：
#   - 每个任务都有技能路由、可能涉及的文件、测试计划和回滚说明
check_gate_g3() {
    local feature_dir="$1"
    local missing=()
    local warnings=()

    local task_map="$feature_dir/03-task-skill-map.md"
    check_file "$task_map" 200 "03-task-skill-map.md"
    local rc=$?
    case $rc in
        1) missing+=("03-task-skill-map.md（文件不存在）") ;;
        2) warnings+=("03-task-skill-map.md 文件过小（<200 bytes），可能为空白模板") ;;
    esac

    if [ -f "$task_map" ]; then
        local head_data
        head_data=$(head -100 "$task_map" 2>/dev/null)

        # 必须包含任务表格或 Task ID
        if ! echo "$head_data" | safe_igrep "task id" && ! echo "$head_data" | grep -qF "|" ; then
            warnings+=("任务映射表缺少任务表格——每个任务需有 Task ID")
        fi

        # 检查技能路由
        if ! echo "$head_data" | safe_igrep "skill" && ! echo "$head_data" | grep -qF "技能" \
            && ! echo "$head_data" | safe_igrep "route"; then
            warnings+=("任务映射表缺少技能路由（Skill/路由）字段")
        fi

        # 检查回滚说明
        if ! echo "$head_data" | safe_igrep "rollback" && ! echo "$head_data" | grep -qF "回滚"; then
            warnings+=("任务映射表缺少回滚说明（Rollback）列")
        fi
    fi

    local status="pass"
    [ ${#missing[@]} -gt 0 ] && status="fail"

    append_gate_result "G3" "$status" "${missing[@]}" --warnings "${warnings[@]}"
}

# ---- G4: 实现就绪 -----------------------------------------------------------
# 参考 AGENTS.md 门禁 4：
#   - 仅实现标记为已批准的任务
#   - 不要将无关的重构混入实现任务中
#   注意：实际代码变更需人工审查，脚本只能检查实现计划文档是否存在
check_gate_g4() {
    local feature_dir="$1"
    local missing=()
    local warnings=()

    local impl_plan="$feature_dir/04-implementation-plan.md"
    check_file "$impl_plan" 100 "04-implementation-plan.md"
    local rc=$?
    case $rc in
        1) missing+=("04-implementation-plan.md（文件不存在）") ;;
        2) warnings+=("04-implementation-plan.md 文件过小（<100 bytes），可能为空白模板") ;;
    esac

    if [ -f "$impl_plan" ]; then
        local head_data
        head_data=$(head -80 "$impl_plan" 2>/dev/null)

        # 检查是否列出了已批准的任务范围
        if ! echo "$head_data" | safe_igrep "approved scope" && ! echo "$head_data" | grep -qF "批准" \
            && ! echo "$head_data" | safe_igrep "task id"; then
            warnings+=("实现计划缺少「已批准范围」章节——需明确引用已批准的 Task ID")
        fi

        # 检查是否有 Actual Files 记录（表明实际实现已完成）
        if ! echo "$head_data" | safe_igrep "actual" && ! echo "$head_data" | grep -qF "实际" \
            && ! echo "$head_data" | safe_igrep "files to touch"; then
            warnings+=("实现计划缺少实际文件记录——实现可能尚未开始或未更新")
        fi
    fi

    local status="pass"
    [ ${#missing[@]} -gt 0 ] && status="fail"

    append_gate_result "G4" "$status" "${missing[@]}" --warnings "${warnings[@]}"
}

# ---- G5: 审查就绪 -----------------------------------------------------------
# 参考 AGENTS.md 门禁 5：
#   - 当两个 Agent 都可用时，两份审查均已完成（dual-agent → 2 份）
#   - 若一方不可用，可用方完成审查并标记为 single-agent
check_gate_g5() {
    local feature_dir="$1"
    local missing=()
    local warnings=()
    local state_file="$feature_dir/feature-state.json"

    local review_dir="$feature_dir/reviews"

    # 检查 reviews/ 目录
    if [ ! -d "$review_dir" ]; then
        missing+=("reviews/（目录不存在——需至少一份审查报告）")
        append_gate_result "G5" "fail" "${missing[@]}" --warnings "${warnings[@]}"
        return
    fi

    local md_count
    md_count=$(count_files_in_dir "$review_dir" "*.md")

    if [ "$md_count" -eq 0 ]; then
        missing+=("reviews/ 目录存在但无 .md 审查报告")
        append_gate_result "G5" "fail" "${missing[@]}" --warnings "${warnings[@]}"
        return
    fi

    # 检查是否存在 codex-review.md 和 claude-review.md
    local has_codex=false
    local has_claude=false
    [ -f "$review_dir/codex-review.md" ] && has_codex=true
    [ -f "$review_dir/claude-review.md" ] && has_claude=true

    # 读取模式以判断是否需要 2 份审查
    local mode
    mode=$(read_feature_mode "$state_file")

    if [ "$mode" = "dual-agent" ]; then
        if [ "$has_codex" = false ] && [ "$has_claude" = false ]; then
            warnings+=("dual-agent 模式下缺少标准审查报告（codex-review.md / claude-review.md）——但有 $md_count 份其他报告")
        elif [ "$has_codex" = false ]; then
            warnings+=("dual-agent 模式缺少 Codex 审查报告（codex-review.md）")
        elif [ "$has_claude" = false ]; then
            warnings+=("dual-agent 模式缺少 Claude 审查报告（claude-review.md）")
        fi
    else
        # single-agent 模式，1 份审查即可
        if [ "$md_count" -lt 1 ]; then
            missing+=("reviews/ 需要至少 1 份审查报告")
        fi
    fi

    # 对每份存在的审查报告做基本内容检查
    for review_file in "$review_dir"/*.md; do
        [ ! -f "$review_file" ] && continue
        local review_name="${review_file##*/}"
        local head_data
        head_data=$(head -60 "$review_file" 2>/dev/null)

        # 检查是否标注了 single-agent
        if ! echo "$head_data" | safe_igrep "dual-agent" && ! echo "$head_data" | safe_igrep "single-agent"; then
            warnings+=("$review_name 缺少审查模式标注（dual-agent / single-agent）")
        fi

        # 检查是否有 Final Review Decision
        if ! echo "$head_data" | safe_igrep "final review" && ! echo "$head_data" | safe_igrep "decision:" && ! echo "$head_data" | grep -qF "审查决定"; then
            warnings+=("$review_name 缺少最终审查决定（Final Review / Decision）")
        fi
    done

    local status="pass"
    [ ${#missing[@]} -gt 0 ] && status="fail"

    append_gate_result "G5" "$status" "${missing[@]}" --warnings "${warnings[@]}"
}

# ---- G6: 已验证 -------------------------------------------------------------
# 参考 AGENTS.md 门禁 6：
#   - 测试、手动检查或有理由的无测试说明已记录
#   - 残余风险明确列出
check_gate_g6() {
    local feature_dir="$1"
    local missing=()
    local warnings=()

    local verify_log="$feature_dir/05-verification-log.md"
    check_file "$verify_log" 100 "05-verification-log.md"
    local rc=$?
    case $rc in
        1) missing+=("05-verification-log.md（文件不存在）") ;;
        2) warnings+=("05-verification-log.md 文件过小（<100 bytes），可能为空白模板") ;;
    esac

    if [ -f "$verify_log" ]; then
        local head_data
        head_data=$(head -100 "$verify_log" 2>/dev/null)

        # 检查验收标准追踪
        if ! echo "$head_data" | safe_igrep "acceptance" && ! echo "$head_data" | grep -qF "验收"; then
            warnings+=("验证日志缺少「验收标准追溯」章节")
        fi

        # 检查测试记录
        if ! echo "$head_data" | safe_igrep "test" && ! echo "$head_data" | grep -qF "测试" \
            && ! echo "$head_data" | safe_igrep "unit" && ! echo "$head_data" | safe_igrep "integration" \
            && ! echo "$head_data" | safe_igrep "manual"; then
            warnings+=("验证日志缺少测试记录（Unit/Integration/Manual）")
        fi

        # 检查残余风险
        if ! echo "$head_data" | safe_igrep "residual risk" && ! echo "$head_data" | grep -qF "残余风险"; then
            warnings+=("验证日志缺少「残余风险」记录")
        fi

        # 检查最终决定
        if ! echo "$head_data" | safe_igrep "ship" && ! echo "$head_data" | safe_igrep "hold" \
            && ! echo "$head_data" | grep -qF "最终决定"; then
            warnings+=("验证日志缺少最终发布决定（Ship/Hold）")
        fi
    fi

    local status="pass"
    [ ${#missing[@]} -gt 0 ] && status="fail"

    append_gate_result "G6" "$status" "${missing[@]}" --warnings "${warnings[@]}"
}

# ---- G7: 知识已捕获 ---------------------------------------------------------
# 参考 AGENTS.md 门禁 7：
#   - 具有未来影响的架构决策已记录在 ADR 中
#   - 显著的失败、工具问题或有用的模式已记录在任务回顾中
check_gate_g7() {
    local feature_dir="$1"
    local missing=()
    local warnings=()

    # G7 需要两个制品：ADR + 任务回顾
    local adr="$feature_dir/06-adr.md"
    local retro="$feature_dir/07-task-retro.md"

    # 检查 ADR
    check_file "$adr" 50 "06-adr.md"
    local adr_rc=$?
    case $adr_rc in
        1) missing+=("06-adr.md（文件不存在——架构决策未记录）") ;;
        2) warnings+=("06-adr.md 文件过小（<50 bytes），可能为空白模板") ;;
    esac

    if [ -f "$adr" ] && [ $adr_rc -eq 0 ]; then
        local adr_head
        adr_head=$(head -80 "$adr" 2>/dev/null)

        # ADR 必须包含 Context/Decision/Consequences
        if ! echo "$adr_head" | safe_igrep "context" && ! echo "$adr_head" | safe_igrep "decision"; then
            warnings+=("ADR 缺少 Context/Decision 核心章节")
        fi
        # 检查 Revisit Trigger（可重新审视的条件）
        if ! echo "$adr_head" | safe_igrep "revisit" && ! echo "$adr_head" | grep -qF "重新审视" \
            && ! echo "$adr_head" | safe_igrep "trigger"; then
            warnings+=("ADR 缺少「Revisit Trigger」——未定义何时重新审视此决策")
        fi
    fi

    # 检查任务回顾
    check_file "$retro" 50 "07-task-retro.md"
    local retro_rc=$?
    case $retro_rc in
        1) missing+=("07-task-retro.md（文件不存在——任务回顾未记录）") ;;
        2) warnings+=("07-task-retro.md 文件过小（<50 bytes），可能为空白模板") ;;
    esac

    if [ -f "$retro" ] && [ $retro_rc -eq 0 ]; then
        local retro_head
        retro_head=$(head -80 "$retro" 2>/dev/null)

        # 任务回顾必须包含经验教训
        if ! echo "$retro_head" | safe_igrep "what worked" && ! echo "$retro_head" | safe_igrep "what failed" \
            && ! echo "$retro_head" | safe_igrep "reusable pattern" && ! echo "$retro_head" | grep -qF "成功" \
            && ! echo "$retro_head" | grep -qF "失败" && ! echo "$retro_head" | grep -qF "可复用"; then
            warnings+=("任务回顾缺少经验教训章节（What Worked / What Failed）")
        fi
        # 检查是否有后续任务
        if ! echo "$retro_head" | safe_igrep "follow-up" && ! echo "$retro_head" | grep -qF "后续" \
            && ! echo "$retro_head" | safe_igrep "knowledge to carry"; then
            warnings+=("任务回顾缺少「后续任务」或「知识传承」章节")
        fi
    fi

    local status="pass"
    [ ${#missing[@]} -gt 0 ] && status="fail"

    append_gate_result "G7" "$status" "${missing[@]}" --warnings "${warnings[@]}"
}

# ---- 主入口 ----------------------------------------------------------------

main() {
    # ====================================================================
    # 参数解析（支持 --enforce / --schema-only / --json 标志）
    # ====================================================================
    FEATURE_ID=""
    TARGET_GATE_RAW=""

    for arg in "$@"; do
        case "$arg" in
            --enforce)
                ENFORCE_MODE=true
                ;;
            --schema-only)
                SCHEMA_ONLY_MODE=true
                ;;
            --json)
                JSON_MODE=true
                ;;
            -*)
                # 未知标志
                echo "{\"error\":\"未知标志: '$arg'。支持: --enforce, --schema-only, --json\"}" >&2
                exit 2
                ;;
            *)
                if [ -z "$FEATURE_ID" ]; then
                    FEATURE_ID="$arg"
                elif [ -z "$TARGET_GATE_RAW" ]; then
                    TARGET_GATE_RAW="$arg"
                fi
                ;;
        esac
    done

    # ---- 参数校验 ----
    if [ -z "$FEATURE_ID" ]; then
        cat >&2 <<EOF
用法: $SCRIPT_NAME <feature-id> [target-gate] [flags]

参数:
  feature-id      功能目录名（位于 $FEATURES_DIR/<feature-id>/）
  target-gate     目标门禁 G1-G7（默认 G7，即检查全部）
  --enforce       强制执行模式：若 fail，输出阻止指令 JSON 并退出非零
  --schema-only   仅校验 feature-state.json 结构，不检查门禁产物
  --json          增强 JSON 输出，添加 machine-readable 字段

示例:
  $SCRIPT_NAME my-feature                # 检查全部 7 个门禁
  $SCRIPT_NAME my-feature G3             # 仅检查 G1 到 G3
  $SCRIPT_NAME my-feature --enforce      # CI 强制执行检查
  $SCRIPT_NAME my-feature --schema-only  # 仅校验 feature-state.json
  $SCRIPT_NAME my-feature G5 --json      # 检查 G1-G5，输出 machine-readable JSON

退出码: 0=通过, 1=存在失败, 2=脚本错误
EOF
        exit 2
    fi

    # ---- 互斥检查 ----
    if [ "$ENFORCE_MODE" = true ] && [ "$SCHEMA_ONLY_MODE" = true ]; then
        echo "{\"error\":\"--enforce 与 --schema-only 互斥，请仅指定一个\"}" >&2
        exit 2
    fi

    # ---- 标准化目标门禁 ----
    TARGET_GATE=$(normalize_gate "${TARGET_GATE_RAW:-G7}")
    if [ -z "$TARGET_GATE" ]; then
        echo "{\"error\":\"无效的门禁编号: '${TARGET_GATE_RAW:-}'。接受 G1-G7 / gate-1..gate-7 / 1..7 / all\"}" >&2
        exit 2
    fi

    FEATURE_DIR="$FEATURES_DIR/$FEATURE_ID"
    STATE_FILE="$FEATURE_DIR/feature-state.json"

    # ---- 检查功能目录是否存在 ----
    if [ ! -d "$FEATURE_DIR" ]; then
        echo "{"
        echo "  \"error\": \"功能目录不存在: $FEATURE_DIR\","
        echo "  \"hint\": \"请先创建功能目录并编写 01-openspec-proposal.md\""
        echo "}"
        exit 2
    fi

    # ====================================================================
    # --schema-only 模式：仅校验 feature-state.json，提前返回
    # ====================================================================
    if [ "$SCHEMA_ONLY_MODE" = true ]; then
        schema_only_check "$STATE_FILE"
        exit $?
    fi

    # ---- 可选：feature-state.json 结构检查 ----
    local schema_warnings
    schema_warnings=$(validate_state_json "$STATE_FILE" 2>&1)
    if [ -n "$schema_warnings" ]; then
        # 将 schema 级别的 warning 附加到 WARNINGS_GLOBAL
        WARNINGS_GLOBAL="$schema_warnings"
    fi

    # ---- 读取当前状态以辅助判断 ----
    local current_state
    current_state=$(read_feature_state "$STATE_FILE")
    local feature_mode
    feature_mode=$(read_feature_mode "$STATE_FILE")

    # 状态 → 应该通过的最大门禁映射
    declare -A STATE_GATE
    STATE_GATE["S0"]="G1"
    STATE_GATE["S1"]="G1"
    STATE_GATE["S2"]="G1"
    STATE_GATE["S3"]="G2"
    STATE_GATE["S4"]="G3"
    STATE_GATE["S5"]="G4"
    STATE_GATE["S6"]="G5"
    STATE_GATE["S7"]="G6"
    STATE_GATE["S8"]="G7"
    STATE_GATE["S9"]="G7"

    # 所有门禁的编号顺序
    local ALL_GATES=("G1" "G2" "G3" "G4" "G5" "G6" "G7")
    local target_num="${TARGET_GATE#G}"

    # ---- 逐门禁检查 ----
    for gate in "${ALL_GATES[@]}"; do
        local gate_num="${gate#G}"

        # 如果目标门禁小于当前门禁，停止
        if [ "$gate_num" -gt "$target_num" ] 2>/dev/null; then
            break
        fi

        case "$gate" in
            G1) check_gate_g1 "$FEATURE_DIR" ;;
            G2) check_gate_g2 "$FEATURE_DIR" ;;
            G3) check_gate_g3 "$FEATURE_DIR" ;;
            G4) check_gate_g4 "$FEATURE_DIR" ;;
            G5) check_gate_g5 "$FEATURE_DIR" ;;
            G6) check_gate_g6 "$FEATURE_DIR" ;;
            G7) check_gate_g7 "$FEATURE_DIR" ;;
        esac

        # 更新全局退出码：任一 fail 则整体 fail
        local last_gate_status
        last_gate_status=$(echo "$RESULTS_JSON" | tail -1 | grep '"status"' | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [ "$last_gate_status" = "fail" ]; then
            EXIT_CODE=1
        fi
    done

    # ====================================================================
    # --enforce 模式：若 fail，输出阻止指令后退出
    # ====================================================================
    if [ "$ENFORCE_MODE" = true ]; then
        # 先统计实际 pass/fail 数量（从累积结果中计算，避免硬编码）
        local enf_passed=0
        local enf_failed=0
        while IFS= read -r line; do
            case "$line" in
                *'"status":"pass"'*) enf_passed=$((enf_passed + 1)) ;;
                *'"status":"fail"'*) enf_failed=$((enf_failed + 1)) ;;
            esac
        done <<< "$RESULTS_JSON"

        if [ $EXIT_CODE -ne 0 ] && [ -n "$FIRST_FAILED_GATE" ]; then
            output_enforce_blocked "$FIRST_FAILED_GATE" "$enf_passed" "$enf_failed"
            # output_enforce_blocked 内部 exit 1，不会到达这里
        else
            output_enforce_pass
            # output_enforce_pass 内部 exit 0，不会到达这里
        fi
    fi

    # ---- 组装最终 JSON 输出 ----
    local summary_status="pass"
    [ $EXIT_CODE -ne 0 ] && summary_status="fail"

    # --json 模式或普通模式都输出此元数据
    local decision="proceed"
    [ "$summary_status" = "fail" ] && decision="block"

    local state_info_json="null"
    if [ -f "$STATE_FILE" ]; then
        local escaped_dir
        escaped_dir=$(json_escape "$FEATURE_DIR")
        local escaped_state
        escaped_state=$(json_escape "$current_state")
        local escaped_mode
        escaped_mode=$(json_escape "$feature_mode")
        state_info_json="{\"featureDir\":\"$escaped_dir\",\"currentState\":\"$escaped_state\",\"mode\":\"$escaped_mode\"}"
    fi

    local global_warnings_json
    if [ -n "$WARNINGS_GLOBAL" ]; then
        # 将多行转为 JSON 字符串数组
        local gw_arr="["
        local first_gw=true
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ "$first_gw" = true ]; then first_gw=false; else gw_arr+=","; fi
            local escaped_line
            escaped_line=$(json_escape "$line")
            gw_arr+="\"$escaped_line\""
        done <<< "$WARNINGS_GLOBAL"
        gw_arr+="]"
        global_warnings_json="$gw_arr"
    else
        global_warnings_json="[]"
    fi

    # 统计概要
    local total_passed=0
    local total_failed=0

    # 使用 grep 从累积结果中统计（纯 shell 方式）
    while IFS= read -r line; do
        case "$line" in
            *'"status":"pass"'*) total_passed=$((total_passed + 1)) ;;
            *'"status":"fail"'*) total_failed=$((total_failed + 1)) ;;
        esac
    done <<< "$RESULTS_JSON"

    # --json 模式的额外 machine-readable 字段
    local decision_json=""
    local failed_gate_json="null"
    local failed_reason_json="null"
    if [ "$JSON_MODE" = true ] || [ -n "$FIRST_FAILED_GATE" ]; then
        if [ -n "$FIRST_FAILED_GATE" ]; then
            local escaped_fg
            escaped_fg=$(json_escape "$FIRST_FAILED_GATE")
            failed_gate_json="\"$escaped_fg\""
            local escaped_fr
            escaped_fr=$(json_escape "$FIRST_FAILED_REASON")
            failed_reason_json="\"$escaped_fr\""
        fi
    fi

    # 构建 decision 字段（machine-readable，dispatch.sh 核心消费字段）
    local decision_str
    decision_str=$(json_escape "$decision")

    # 输出 JSON 结果
    cat <<EOF
{
  "checkAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)",
  "version": "$SCRIPT_VERSION",
  "format": "$OUTPUT_FORMAT",
  "featureId": "$FEATURE_ID",
  "targetGate": "$TARGET_GATE",
  "decision": "$decision_str",
  "failedGate": $failed_gate_json,
  "failedReason": $failed_reason_json,
  "summary": {
    "status": "$summary_status",
    "gatesChecked": $RESULT_COUNT,
    "passed": $total_passed,
    "failed": $total_failed
  },
  "state": $state_info_json,
  "schemaWarnings": $global_warnings_json,
  "gates": [$RESULTS_JSON
  ]
}
EOF

    exit $EXIT_CODE
}

main "$@"
