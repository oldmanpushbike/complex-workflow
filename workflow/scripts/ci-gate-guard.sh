#!/usr/bin/env bash
# ============================================================================
# ci-gate-guard.sh — CI/CD 门禁守护脚本（零 LLM 调用）
# ============================================================================
# 在 CI pipeline 中运行，确保：
#   1. 所有修改的功能代码都有对应的门禁产物
#   2. 不会合并未通过审查的代码到 main
#   3. 评分不低于基线 15 分以上
#
# 设计原则：
#   1. 零 LLM 调用——纯文件系统 + git diff + 确定性脚本
#   2. fail-closed——任何不确定状态 → 返回非零
#   3. 纯 Bash，兼容 Git Bash on Windows——jq 可选
#   4. 退出码 0 = 全部通过，1 = 存在失败，2 = 脚本错误
#   5. 兼容 GitHub Actions 和 GitLab CI
#
# 用法：
#   bash workflow/scripts/ci-gate-guard.sh [--strict] [--feature <feature-id>]
#
# 参数：
#   --strict         严格模式：评分低于基准线的警告也视为失败
#   --feature <id>   仅检查指定功能（默认检查所有受影响的功能）
#   --base-branch    基准分支（默认 main）
#   --baseline-file  基线文件路径（默认 workflow/eval/baselines.json）
#
# 输出：
#   JSON 摘要到 stdout，同时写入 CI 平台的原生输出变量
#
# ============================================================================

set -o pipefail

# ---- 路径配置 ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_DIR="$PROJECT_ROOT/workflow"
FEATURES_DIR="$WORKFLOW_DIR/features"
GATE_CHECK="$SCRIPT_DIR/gate-check.sh"
SCORE_PY="$WORKFLOW_DIR/eval/score.py"
DEFAULT_BASELINE="$WORKFLOW_DIR/eval/baselines.json"

SCRIPT_NAME="${0##*/}"
SCRIPT_VERSION="1.0.0"

# ---- 工具检测 ---------------------------------------------------------------
HAS_JQ=false
command -v jq >/dev/null 2>&1 && HAS_JQ=true

# ---- 默认参数 ---------------------------------------------------------------
STRICT_MODE=false
TARGET_FEATURE=""
BASE_BRANCH="main"
BASELINE_FILE="$DEFAULT_BASELINE"

# ---- 全局状态 ---------------------------------------------------------------
EXIT_CODE=0
FEATURES_CHECKED=()
GATES_ALL_PASSED=true
SCORES_ABOVE_FLOOR=true
UNREGISTERED_CHANGES=()
WARNINGS=()
ERRORS=()
CI_RESULTS=""

# ---- CI 平台检测 -----------------------------------------------------------
CI_PLATFORM="local"
CI_OUTPUT_FILE=""
CI_SUMMARY_FILE=""

detect_ci_platform() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        CI_PLATFORM="github"
        CI_OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"
        CI_SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
    elif [ -n "${GITLAB_CI:-}" ]; then
        CI_PLATFORM="gitlab"
        # GitLab CI uses environment variables for job output
        CI_OUTPUT_FILE=""  # GitLab uses dotenv artifacts or direct env
        CI_SUMMARY_FILE=""  # GitLab uses job log
    elif [ -n "${CI:-}" ]; then
        CI_PLATFORM="generic-ci"
    fi
}

# ============================================================================
# SECTION 1: Helper Functions
# ============================================================================

# JSON 字符串转义（纯 sed，零外部依赖）
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

# 构建 JSON 对象数组（从管道输入，每行一个 JSON 对象字符串）
json_obj_array() {
    local first=true
    local out="["
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$first" = true ]; then first=false; else out+=","; fi
        out+="$line"
    done
    out+="]"
    printf '%s' "$out"
}

# 记录警告
warn() {
    WARNINGS+=("$1")
    echo "::warning::$1" >&2
}

# 记录错误
err() {
    ERRORS+=("$1")
    echo "::error::$1" >&2
}

# 写入 CI 输出变量
ci_set_output() {
    local name="$1"
    local value="$2"
    case "$CI_PLATFORM" in
        github)
            if [ -n "$CI_OUTPUT_FILE" ] && [ "$CI_OUTPUT_FILE" != "/dev/null" ]; then
                echo "$name=$value" >> "$CI_OUTPUT_FILE"
            fi
            ;;
        gitlab)
            # GitLab CI: write to job log as dotenv-compatible
            echo "CI_GATE_${name}=$value"
            ;;
        *)
            # Local — do nothing
            ;;
    esac
}

# 写入 CI 摘要
ci_write_summary() {
    local text="$1"
    case "$CI_PLATFORM" in
        github)
            if [ -n "$CI_SUMMARY_FILE" ] && [ "$CI_SUMMARY_FILE" != "/dev/null" ]; then
                echo "$text" >> "$CI_SUMMARY_FILE"
            fi
            ;;
        *)
            # Other platforms — print to stdout with marker
            echo "##[summary]$text"
            ;;
    esac
}

# ============================================================================
# SECTION 2: Git Diff Analysis
# ============================================================================

# 获取变更文件列表（相对于项目根目录）
get_changed_files() {
    local base="$1"
    local changed_files=()

    # 检查是否在 git 仓库中
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        err "不在 Git 仓库中，无法获取变更文件"
        return 2
    fi

    # 确保 base 分支存在
    if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
        # 尝试 origin/<base>
        if git rev-parse --verify "origin/$base" >/dev/null 2>&1; then
            base="origin/$base"
        else
            err "基准分支 '$base' 不存在"
            return 2
        fi
    fi

    # 获取变更文件（仅新增/修改/删除的文件，不包含未跟踪文件）
    local raw_files
    raw_files=$(git diff --name-only --diff-filter=ACMRT "$base...HEAD" 2>/dev/null || true)

    if [ -z "$raw_files" ]; then
        # 当前分支与 base 无差异，尝试 HEAD~1 作为兜底
        raw_files=$(git diff --name-only --diff-filter=ACMRT HEAD~1...HEAD 2>/dev/null || true)
    fi

    # 转换为绝对路径数组
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        changed_files+=("$PROJECT_ROOT/$file")
    done <<< "$raw_files"

    printf '%s\n' "${changed_files[@]}"
}

# ============================================================================
# SECTION 3: Feature Mapping
# ============================================================================

# 将文件路径映射到受影响的功能 ID 列表
# 返回格式：每行一个 feature-id（可能重复，调用者自行去重）
map_files_to_features() {
    local changed_files=("$@")
    local feature_ids=()

    for file in "${changed_files[@]}"; do
        # 检查文件是否在 workflow/features/<id>/ 下
        local rel_path="${file#$PROJECT_ROOT/}"
        if [[ "$rel_path" == workflow/features/* ]]; then
            # 提取 feature-id（路径的第二级目录）
            local feature_id
            feature_id=$(echo "$rel_path" | cut -d'/' -f3)
            if [ -n "$feature_id" ] && [ "$feature_id" != "*" ]; then
                echo "$feature_id"
            fi
        fi
    done
}

# 获取所有存在的功能 ID
get_all_features() {
    if [ ! -d "$FEATURES_DIR" ]; then
        return 0
    fi
    for dir in "$FEATURES_DIR"/*/; do
        [ ! -d "$dir" ] && continue
        local feature_id
        feature_id=$(basename "$dir")
        # 跳过非功能目录
        [ "$feature_id" = "*" ] && continue
        echo "$feature_id"
    done
}

# 获取某个功能的 requiredArtifacts 列表（从 feature-state.json）
# 返回相对于项目根目录的绝对路径
get_feature_artifacts() {
    local feature_id="$1"
    local state_file="$FEATURES_DIR/$feature_id/feature-state.json"

    if [ ! -f "$state_file" ]; then
        return 0
    fi

    if [ "$HAS_JQ" = true ]; then
        jq -r '.gates[].artifacts[]? // empty' "$state_file" 2>/dev/null | while IFS= read -r artifact; do
            [ -z "$artifact" ] && continue
            echo "$FEATURES_DIR/$feature_id/$artifact"
        done
    else
        # grep 降级：提取 "artifacts": ["..."] 中的路径
        grep -o '"[^"]*\.md"' "$state_file" 2>/dev/null | tr -d '"' | while IFS= read -r artifact; do
            [ -z "$artifact" ] && continue
            # 仅保留看起来像产物文件名（而非 gateId 等）
            case "$artifact" in
                *.md|*.json|*.txt|*.html|*.yaml|*.yml|*.toml)
                    echo "$FEATURES_DIR/$feature_id/$artifact"
                    ;;
            esac
        done
    fi
}

# 检测未注册的变更
# 返回：未匹配任何功能的文件路径列表
detect_unregistered_changes() {
    local changed_files=("$@")
    local unregistered=()

    # 收集所有功能的所有产物路径
    local all_artifacts=()
    local all_feature_dirs=()
    while IFS= read -r feature_id; do
        [ -z "$feature_id" ] && continue
        all_feature_dirs+=("$FEATURES_DIR/$feature_id")
        while IFS= read -r artifact; do
            [ -z "$artifact" ] && continue
            all_artifacts+=("$artifact")
        done < <(get_feature_artifacts "$feature_id")
    done < <(get_all_features)

    for file in "${changed_files[@]}"; do
        local matched=false

        # 1. 检查是否在任何功能文件夹下
        for fdir in "${all_feature_dirs[@]}"; do
            if [[ "$file" == "$fdir"/* ]]; then
                matched=true
                break
            fi
        done
        [ "$matched" = true ] && continue

        # 2. 检查是否是 workflow 基础设施文件（豁免）
        local rel_path="${file#$PROJECT_ROOT/}"
        if [[ "$rel_path" == workflow/* ]] && [[ "$rel_path" != workflow/features/* ]]; then
            # 工作流基础设施文件，不算未注册
            continue
        fi

        # 3. 检查是否在任何功能的 artifacts 列表中
        for art in "${all_artifacts[@]}"; do
            if [ "$file" = "$art" ]; then
                matched=true
                break
            fi
        done
        [ "$matched" = true ] && continue

        # 4. 豁免常见的非代码文件（配置文件、CI 文件等）
        case "$rel_path" in
            .gitignore|.gitattributes|.editorconfig|*.md|LICENSE|README*|CHANGELOG*)
                continue
                ;;
            .github/*|.gitlab/*|.circleci/*|Jenkinsfile|Makefile|Dockerfile|docker-compose*)
                continue
                ;;
            package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|*.lock)
                continue
                ;;
        esac

        # 标记为未注册
        unregistered+=("$rel_path")
    done

    printf '%s\n' "${unregistered[@]}"
}

# ============================================================================
# SECTION 4: Gate Check Runner
# ============================================================================

# 对单个功能运行门禁检查
# 输出 JSON 对象字符串，包含 featureId, gatePassed, gateDetails
run_gate_check() {
    local feature_id="$1"
    local gate_output
    local gate_rc

    if [ ! -f "$GATE_CHECK" ]; then
        echo "{\"featureId\":\"$feature_id\",\"gatePassed\":false,\"error\":\"gate-check.sh 不可用\"}"
        return 1
    fi

    gate_output=$(bash "$GATE_CHECK" "$feature_id" --enforce 2>/dev/null) || true
    gate_rc=$?

    local blocked="false"
    local reason=""

    if [ "$HAS_JQ" = true ]; then
        blocked=$(echo "$gate_output" | jq -r '.blocked // "false"' 2>/dev/null)
        reason=$(echo "$gate_output" | jq -r '.reason // ""' 2>/dev/null)
    else
        if echo "$gate_output" | grep -q '"blocked"[[:space:]]*:[[:space:]]*true'; then
            blocked="true"
        fi
        reason=$(echo "$gate_output" | grep -o '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi

    local gate_passed="true"
    if [ "$blocked" = "true" ] || [ "$gate_rc" -ne 0 ]; then
        gate_passed="false"
        GATES_ALL_PASSED=false
    fi

    local escaped_reason
    escaped_reason=$(json_escape "$reason")

    echo "{\"featureId\":\"$feature_id\",\"gatePassed\":$gate_passed,\"reason\":\"$escaped_reason\"}"
    return 0
}

# ============================================================================
# SECTION 5: Score Check
# ============================================================================

# 对单个功能运行评分
# 输出 JSON 对象字符串，包含 totalScore, grade, aboveFloor, baselineTotal, delta
run_score_check() {
    local feature_id="$1"
    local baseline_file="$2"
    local score_output
    local feature_dir="$FEATURES_DIR/$feature_id"

    if [ ! -f "$SCORE_PY" ]; then
        echo "{\"featureId\":\"$feature_id\",\"scoreError\":\"score.py 不可用\"}"
        return 1
    fi

    if [ ! -d "$feature_dir" ]; then
        echo "{\"featureId\":\"$feature_id\",\"scoreError\":\"功能目录不存在\"}"
        return 1
    fi

    # 构建 score.py 参数
    local score_args=("--feature" "$feature_id")
    if [ -n "$baseline_file" ] && [ -f "$baseline_file" ]; then
        score_args+=("--baseline" "$baseline_file")
    fi

    # 运行评分（捕获 stdout 中的最后一行 JSON）
    score_output=$(python3 "$SCORE_PY" "${score_args[@]}" 2>/dev/null) || true

    # 提取最后一行的 JSON（score.py 会先打印 human-readable 行，最后打印 JSON）
    local score_json
    if [ "$HAS_JQ" = true ]; then
        # 找到有效的 JSON 行
        score_json=$(echo "$score_output" | jq -e '.featureId' 2>/dev/null | head -1)
        if [ -z "$score_json" ]; then
            # 尝试取最后一个以 { 开头的块
            score_json=$(echo "$score_output" | grep -E '^\{"featureId"' | tail -1)
        else
            # jq -e 只验证不输出内容，需要重新提取
            score_json=$(echo "$score_output" | jq -e 'select(.featureId != null)' 2>/dev/null | tail -1)
        fi
    else
        score_json=$(echo "$score_output" | grep -E '^\{"featureId"' | tail -1)
    fi

    if [ -z "$score_json" ]; then
        echo "{\"featureId\":\"$feature_id\",\"scoreError\":\"无法解析评分输出\"}"
        return 1
    fi

    # 从评分 JSON 中提取关键字段
    local total_score
    local grade
    local baseline_total
    local delta
    local bl_status

    if [ "$HAS_JQ" = true ]; then
        total_score=$(echo "$score_json" | jq -r '.scores.total // "null"' 2>/dev/null)
        grade=$(echo "$score_json" | jq -r '.scores.grade // "N/A"' 2>/dev/null)
        baseline_total=$(echo "$score_json" | jq -r '.baselineComparison.baselineTotal // "null"' 2>/dev/null)
        delta=$(echo "$score_json" | jq -r '.baselineComparison.delta // "null"' 2>/dev/null)
        bl_status=$(echo "$score_json" | jq -r '.baselineComparison.status // "no_baseline"' 2>/dev/null)
    else
        total_score=$(echo "$score_json" | grep -o '"total"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/.*:[[:space:]]*\([0-9]*\).*/\1/')
        [ -z "$total_score" ] && total_score="null"
        grade=$(echo "$score_json" | grep -o '"grade"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')
        [ -z "$grade" ] && grade="N/A"
        baseline_total=$(echo "$score_json" | grep -o '"baselineTotal"[[:space:]]*:[[:space:]]*[0-9]*' | sed 's/.*:[[:space:]]*\([0-9]*\).*/\1/')
        [ -z "$baseline_total" ] && baseline_total="null"
        delta=$(echo "$score_json" | grep -o '"delta"[[:space:]]*:[[:space:]]*-\?[0-9]*' | sed 's/.*:[[:space:]]*\(-\?[0-9]*\).*/\1/')
        [ -z "$delta" ] && delta="null"
        bl_status="no_baseline"
    fi

    # 判断是否低于基线 15 分以上
    local above_floor=true
    local floor_warning=""

    if [ "$baseline_total" != "null" ] && [ "$total_score" != "null" ] \
        && [ -n "$baseline_total" ] && [ -n "$total_score" ]; then
        local diff=$(( total_score - baseline_total ))
        if [ "$diff" -le -15 ] 2>/dev/null; then
            above_floor=false
            SCORES_ABOVE_FLOOR=false
            floor_warning="评分 $total_score 低于基线 $baseline_total 超过 15 分 (delta=$diff)"
            warn "Feature '$feature_id': $floor_warning"
        fi
    fi

    local escaped_warning
    escaped_warning=$(json_escape "$floor_warning")

    cat <<EOF
{
  "featureId": "$feature_id",
  "totalScore": $total_score,
  "grade": "$grade",
  "baselineTotal": $baseline_total,
  "delta": $delta,
  "aboveFloor": $above_floor,
  "floorWarning": "$escaped_warning"
}
EOF
}

# ============================================================================
# SECTION 6: Summary & Output
# ============================================================================

# 收集每个受检查功能的完整结果
# 全局变量存储各个功能的结果 JSON 行
FEATURE_RESULTS=()

check_feature() {
    local feature_id="$1"
    local baseline_file="$2"

    echo "--- 检查功能: $feature_id ---" >&2

    FEATURES_CHECKED+=("$feature_id")

    # 运行门禁检查
    local gate_result
    gate_result=$(run_gate_check "$feature_id")
    local gate_passed
    if [ "$HAS_JQ" = true ]; then
        gate_passed=$(echo "$gate_result" | jq -r '.gatePassed // "false"' 2>/dev/null)
    else
        gate_passed=$(echo "$gate_result" | grep -o '"gatePassed":[[:space:]]*[a-z]*' | sed 's/.*:[[:space:]]*\([a-z]*\).*/\1/')
    fi
    echo "  门禁检查: $gate_passed" >&2

    # 运行评分检查
    local score_result
    score_result=$(run_score_check "$feature_id" "$baseline_file")
    local total_score
    local above_floor
    if [ "$HAS_JQ" = true ]; then
        total_score=$(echo "$score_result" | jq -r '.totalScore // "null"' 2>/dev/null)
        above_floor=$(echo "$score_result" | jq -r '.aboveFloor // "true"' 2>/dev/null)
    else
        total_score=$(echo "$score_result" | grep -o '"totalScore":[[:space:]]*[0-9]*' | sed 's/.*:[[:space:]]*\([0-9]*\).*/\1/')
        above_floor=$(echo "$score_result" | grep -o '"aboveFloor":[[:space:]]*[a-z]*' | sed 's/.*:[[:space:]]*\([a-z]*\).*/\1/')
    fi
    echo "  评分: $total_score, 高于底线: $above_floor" >&2

    # 组合特征结果
    local escaped_gate
    escaped_gate=$(json_escape "$gate_result")
    local escaped_score
    escaped_score=$(json_escape "$score_result")

    FEATURE_RESULTS+=("{\"featureId\":\"$feature_id\",\"gateCheck\":$escaped_gate,\"scoreCheck\":$escaped_score}")
}

# 生成完整 CI 摘要
generate_summary() {
    local ci_passed=true

    # 判断整体是否通过
    if [ "$GATES_ALL_PASSED" = false ]; then
        ci_passed=false
    fi
    if [ "$SCORES_ABOVE_FLOOR" = false ]; then
        if [ "$STRICT_MODE" = true ]; then
            ci_passed=false
        fi
    fi
    if [ ${#ERRORS[@]} -gt 0 ]; then
        ci_passed=false
    fi
    if [ ${#UNREGISTERED_CHANGES[@]} -gt 0 ] && [ "$STRICT_MODE" = true ]; then
        ci_passed=false
    fi

    # 构建功能结果 JSON 数组
    local features_json="[]"
    if [ ${#FEATURE_RESULTS[@]} -gt 0 ]; then
        features_json="["
        local first=true
        for result in "${FEATURE_RESULTS[@]}"; do
            if [ "$first" = true ]; then first=false; else features_json+=","; fi
            features_json+="$result"
        done
        features_json+="]"
    fi

    local unreg_json
    unreg_json=$(json_str_array "${UNREGISTERED_CHANGES[@]}")

    local warnings_json
    warnings_json=$(json_str_array "${WARNINGS[@]}")

    local errors_json
    errors_json=$(json_str_array "${ERRORS[@]}")

    cat <<EOF
{
  "ciPassed": $ci_passed,
  "ciPlatform": "$CI_PLATFORM",
  "strictMode": $STRICT_MODE,
  "featuresChecked": $features_json,
  "gatesAllPassed": $GATES_ALL_PASSED,
  "scoresAboveFloor": $SCORES_ABOVE_FLOOR,
  "unregisteredChanges": $unreg_json,
  "warnings": $warnings_json,
  "errors": $errors_json,
  "checkedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)",
  "scriptVersion": "$SCRIPT_VERSION"
}
EOF
}

# 生成人类可读的 Markdown 摘要
generate_markdown_summary() {
    local ci_passed=true
    if [ "$GATES_ALL_PASSED" = false ] || [ ${#ERRORS[@]} -gt 0 ]; then
        ci_passed=false
    fi
    if [ "$SCORES_ABOVE_FLOOR" = false ] && [ "$STRICT_MODE" = true ]; then
        ci_passed=false
    fi

    # 状态图标
    local status_icon="✅ 通过"
    if [ "$ci_passed" = false ]; then
        status_icon="❌ 失败"
    elif [ "$SCORES_ABOVE_FLOOR" = false ] || [ ${#UNREGISTERED_CHANGES[@]} -gt 0 ]; then
        status_icon="⚠️ 警告"
    fi

    cat <<EOF
## CI Gate Guard 检查结果 $status_icon

| 检查项 | 状态 |
|--------|------|
| 门禁全部通过 | $([ "$GATES_ALL_PASSED" = true ] && echo '✅' || echo '❌') |
| 评分高于底线 | $([ "$SCORES_ABOVE_FLOOR" = true ] && echo '✅' || echo '⚠️') |
| 无未注册变更 | $([ ${#UNREGISTERED_CHANGES[@]} -eq 0 ] && echo '✅' || echo '⚠️') |
| 严格模式 | $([ "$STRICT_MODE" = true ] && echo '🔒 开启' || echo '🔓 关闭') |

### 已检查功能
EOF

    if [ ${#FEATURES_CHECKED[@]} -eq 0 ]; then
        echo "_(无功能被修改)_"
    else
        for fid in "${FEATURES_CHECKED[@]}"; do
            echo "- \`$fid\`"
        done
    fi

    if [ ${#UNREGISTERED_CHANGES[@]} -gt 0 ]; then
        echo ""
        echo "### ⚠️ 未注册的变更"
        echo "以下文件在功能工作流之外被修改："
        for f in "${UNREGISTERED_CHANGES[@]}"; do
            echo "- \`$f\`"
        done
    fi

    if [ ${#WARNINGS[@]} -gt 0 ]; then
        echo ""
        echo "### 警告"
        for w in "${WARNINGS[@]}"; do
            echo "- $w"
        done
    fi

    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo ""
        echo "### 错误"
        for e in "${ERRORS[@]}"; do
            echo "- $e"
        done
    fi
}

# ============================================================================
# SECTION 7: Main
# ============================================================================

main() {
    # ---- 参数解析 ----
    while [ $# -gt 0 ]; do
        case "$1" in
            --strict)
                STRICT_MODE=true
                ;;
            --feature)
                shift
                if [ -z "${1:-}" ]; then
                    echo "{\"error\":\"--feature 需要参数\"}" >&2
                    exit 2
                fi
                TARGET_FEATURE="$1"
                ;;
            --base-branch)
                shift
                if [ -z "${1:-}" ]; then
                    echo "{\"error\":\"--base-branch 需要参数\"}" >&2
                    exit 2
                fi
                BASE_BRANCH="$1"
                ;;
            --baseline-file)
                shift
                if [ -z "${1:-}" ]; then
                    echo "{\"error\":\"--baseline-file 需要参数\"}" >&2
                    exit 2
                fi
                BASELINE_FILE="$1"
                ;;
            --help|-h)
                cat <<'HELP'
用法: ci-gate-guard.sh [选项]

在 CI pipeline 中运行门禁守护检查。

选项:
  --strict              严格模式：评分警告和未注册变更也视为失败
  --feature <id>        仅检查指定功能（默认检查所有受影响的功能）
  --base-branch <ref>   基准分支（默认: main）
  --baseline-file <path> 基线文件路径（默认: workflow/eval/baselines.json）
  --help, -h            显示此帮助

退出码:
  0 — 全部通过
  1 — 存在失败
  2 — 脚本错误
HELP
                exit 0
                ;;
            *)
                echo "{\"error\":\"未知参数: '$1'\"}" >&2
                exit 2
                ;;
        esac
        shift
    done

    # ---- CI 平台检测 ----
    detect_ci_platform

    echo "=== CI Gate Guard v$SCRIPT_VERSION ===" >&2
    echo "  CI 平台: $CI_PLATFORM" >&2
    echo "  严格模式: $STRICT_MODE" >&2
    echo "  基准分支: $BASE_BRANCH" >&2
    echo "  目标功能: ${TARGET_FEATURE:-所有受影响功能}" >&2
    echo "" >&2

    # ---- 获取变更文件 ----
    local changed_files_raw
    changed_files_raw=$(get_changed_files "$BASE_BRANCH") || true
    local changed_files=()
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        changed_files+=("$file")
    done <<< "$changed_files_raw"

    if [ ${#changed_files[@]} -eq 0 ]; then
        echo "未检测到变更文件，所有检查通过。" >&2
        local summary
        summary=$(generate_summary)
        echo "$summary"
        exit 0
    fi

    echo "变更文件 (${#changed_files[@]} 个):" >&2
    for f in "${changed_files[@]}"; do
        local rel="${f#$PROJECT_ROOT/}"
        echo "  $rel" >&2
    done
    echo "" >&2

    # ---- 确定受影响的功能 ----
    local affected_features=()
    if [ -n "$TARGET_FEATURE" ]; then
        # 指定了单个功能
        local target_dir="$FEATURES_DIR/$TARGET_FEATURE"
        if [ ! -d "$target_dir" ]; then
            err "指定的功能目录不存在: $target_dir"
            exit 2
        fi
        affected_features=("$TARGET_FEATURE")
    else
        # 从变更文件中提取受影响的功能
        local mapped
        mapped=$(map_files_to_features "${changed_files[@]}" | sort -u)
        while IFS= read -r fid; do
            [ -z "$fid" ] && continue
            affected_features+=("$fid")
        done <<< "$mapped"

        # 如果没有功能文件被修改，检查是否有其他代码变更
        # 此时仍需要运行检测（可能所有变更都是未注册的）
    fi

    echo "受影响的功能 (${#affected_features[@]} 个):" >&2
    for fid in "${affected_features[@]}"; do
        echo "  $fid" >&2
    done
    echo "" >&2

    # ---- 检查每个受影响的功能 ----
    for fid in "${affected_features[@]}"; do
        check_feature "$fid" "$BASELINE_FILE"
    done

    # ---- 检测未注册的变更 ----
    echo "--- 检测未注册变更 ---" >&2
    local unreg_raw
    unreg_raw=$(detect_unregistered_changes "${changed_files[@]}") || true
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        UNREGISTERED_CHANGES+=("$f")
    done <<< "$unreg_raw"

    if [ ${#UNREGISTERED_CHANGES[@]} -gt 0 ]; then
        local msg="${#UNREGISTERED_CHANGES[@]} 个文件在功能工作流之外被修改"
        if [ "$STRICT_MODE" = true ]; then
            err "$msg（严格模式：视为失败）"
        else
            warn "$msg"
        fi
        for f in "${UNREGISTERED_CHANGES[@]}"; do
            echo "  未注册: $f" >&2
        done
    else
        echo "  所有变更文件均已注册 ✅" >&2
    fi
    echo "" >&2

    # ---- 生成最终输出 ----
    local summary
    summary=$(generate_summary)
    echo "$summary"

    # ---- 写入 CI 平台原生输出 ----
    local ci_passed
    if [ "$HAS_JQ" = true ]; then
        ci_passed=$(echo "$summary" | jq -r '.ciPassed // "false"' 2>/dev/null)
    else
        ci_passed=$(echo "$summary" | grep -o '"ciPassed":[[:space:]]*[a-z]*' | sed 's/.*:[[:space:]]*\([a-z]*\).*/\1/')
    fi

    ci_set_output "PASSED" "$([ "$ci_passed" = true ] && echo "true" || echo "false")"
    ci_set_output "GATES_PASSED" "$([ "$GATES_ALL_PASSED" = true ] && echo "true" || echo "false")"
    ci_set_output "SCORES_ABOVE_FLOOR" "$([ "$SCORES_ABOVE_FLOOR" = true ] && echo "true" || echo "false")"
    ci_set_output "UNREGISTERED_COUNT" "${#UNREGISTERED_CHANGES[@]}"

    # ---- 写入 Markdown 摘要 ----
    local md_summary
    md_summary=$(generate_markdown_summary)
    ci_write_summary "$md_summary"

    # ---- 确定退出码 ----
    if [ ${#ERRORS[@]} -gt 0 ]; then
        EXIT_CODE=1
    fi
    if [ "$GATES_ALL_PASSED" = false ]; then
        EXIT_CODE=1
    fi
    if [ "$SCORES_ABOVE_FLOOR" = false ] && [ "$STRICT_MODE" = true ]; then
        EXIT_CODE=1
    fi
    if [ ${#UNREGISTERED_CHANGES[@]} -gt 0 ] && [ "$STRICT_MODE" = true ]; then
        EXIT_CODE=1
    fi

    # 确保至少有一个退出条件
    if [ $EXIT_CODE -eq 0 ]; then
        echo "" >&2
        echo "=== ✅ CI Gate Guard: 全部通过 ===" >&2
    else
        echo "" >&2
        echo "=== ❌ CI Gate Guard: 存在失败 ===" >&2
    fi

    exit $EXIT_CODE
}

# ============================================================================
# ENTRY POINT
# ============================================================================
main "$@"
