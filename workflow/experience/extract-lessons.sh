#!/usr/bin/env bash
# ============================================================================
# extract-lessons.sh — 从 07-task-retro.md 确定性提取 Lesson 草稿（零 LLM 调用）
# ============================================================================
# 设计原则：
#   1. 零 LLM 调用——纯字符串匹配 + 文件操作
#   2. 确定性——同一份 retro 永远产出相同的 Lesson
#   3. 安全——已存在的 Lesson 默认不覆盖，除非 --force
#   4. 纯 shell，兼容 Git Bash on Windows——无 python 依赖，jq 可选
#   5. grep 使用 -E 单模式替代多 -e，避免 msys grep 在多字节字符上的已知崩溃 bug
#
# 用法：
#   bash workflow/experience/extract-lessons.sh <feature-id>
#   bash workflow/experience/extract-lessons.sh --all
#   bash workflow/experience/extract-lessons.sh --check
#   bash workflow/experience/extract-lessons.sh <feature-id> --force
#   bash workflow/experience/extract-lessons.sh --all --force
#
# 退出码：
#   0 — 提取成功（或 --check 全部已提取）
#   1 — 存在跳过的 Lesson（已存在且未 --force）
#   2 — 脚本自身错误（参数错误、目录不存在等）
#   3 — --check 发现未提取的 retro
# ============================================================================

set -o pipefail

# ---- 平台兼容性 ---------------------------------------------------------------
# 本系统上 grep -i -F 组合会在多字节字符（中文）上崩溃（msys grep 已知 bug）。
# 解决方案：仅使用 -i（不用 -F），所有匹配模式均为不含正则元字符的纯字面量。
# sed 的 [[:space:]] 在此系统的某些 locale 下也有问题：它被误解析为
# 字面量字符范围 [s-p]（因为 [ 内层未被识别为字符类），s>p 导致 "Invalid range end"。
# 解决方案：使用显式空格+制表符变量替代 [[:space:]]。
TAB=$(printf '\t')
SPC_TAB=" ${TAB}"

# ---- 路径配置 ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FEATURES_DIR="${WORKFLOW_FEATURES_DIR:-$REPO_ROOT/workflow/features}"
LESSONS_DIR="$REPO_ROOT/workflow/experience/lessons"
INDEX_FILE="$LESSONS_DIR/_index.md"
SCRIPT_NAME="${0##*/}"

# ---- 工具检测 ---------------------------------------------------------------
HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
    HAS_JQ=true
fi

# ---- 全局状态 ---------------------------------------------------------------
MODE=""           # single | all | check
FORCE=false
FEATURE_ID=""
EXIT_CODE=0
PROCESSED_COUNT=0
SKIPPED_COUNT=0
CREATED_COUNT=0

# 跨功能 tag 追踪（用于 Pattern 候选检测）
declare -A FEATURE_TAGS   # FEATURE_TAGS[feature-id]="tag1 tag2 tag3"

# ---- 辅助函数 ---------------------------------------------------------------

# 输出 ISO 8601 时间戳（UTC，兼容 Git Bash）
iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ"
}

# 输出带时间戳的日志行
log_info()  { echo "[$(iso_timestamp)] [INFO]  $*"; }
log_warn()  { echo "[$(iso_timestamp)] [WARN]  $*" >&2; }
log_error() { echo "[$(iso_timestamp)] [ERROR] $*" >&2; }

# 打印用法并退出
usage() {
    cat <<EOF
用法: bash $SCRIPT_NAME <feature-id> [--force]
      bash $SCRIPT_NAME --all [--force]
      bash $SCRIPT_NAME --check

从 07-task-retro.md 中确定性提取 Lesson 草稿。零 LLM 调用。

参数:
  <feature-id>    功能目录名（位于 workflow/features/<feature-id>/）
  --all           扫描所有功能
  --check         仅检查是否有未提取的 retro（不生成文件）
  --force         覆盖已存在的 Lesson 文件

退出码:
  0 — 提取成功（或 --check 全部已提取）
  1 — 存在跳过的 Lesson
  2 — 脚本自身错误
  3 — --check 发现未提取的 retro

示例:
  bash $SCRIPT_NAME my-feature
  bash $SCRIPT_NAME my-feature --force
  bash $SCRIPT_NAME --all
  bash $SCRIPT_NAME --check
EOF
    exit 2
}

# 确保目录存在
ensure_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || {
            log_error "无法创建目录: $dir"
            exit 2
        }
    fi
}

# 从 Markdown 文件中提取指定标题下的内容（支持中英文双语标题）
# 参数: $1 = 文件路径, $2..$N = 标题文本（OR 关系，匹配任意一个）
# 输出: 该标题到下一个同级标题之间的内容（不含标题行本身）
# 返回: 0 = 找到, 1 = 未找到
extract_section() {
    local file="$1"
    shift
    # 构建 grep -E 模式：匹配任意一个标题
    local pattern=""
    local first=true
    for heading in "$@"; do
        if [ "$first" = true ]; then first=false; else pattern+="|"; fi
        pattern+="^## ${heading}"
    done

    # 找到起始行号
    local start_line
    start_line=$(grep -n -E "$pattern" "$file" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$start_line" ]; then
        return 1
    fi

    # 找到下一个 ## 标题行（同级或上级）
    local total_lines
    total_lines=$(wc -l < "$file" 2>/dev/null || echo "0")
    total_lines=$(echo "$total_lines" | tr -d '[:space:]')

    local end_line
    end_line=$(tail -n +"$((start_line + 1))" "$file" 2>/dev/null | grep -n "^## " | head -1 | cut -d: -f1)
    if [ -z "$end_line" ]; then
        end_line=$((total_lines - start_line + 1))
    fi

    # 输出内容（跳过起始标题行）
    tail -n +"$((start_line + 1))" "$file" 2>/dev/null | head -n "$((end_line - 1))"
    return 0
}

# 从提取的 section 内容中获取非空列表项（以 "- " 开头的非空行）
# 参数: stdin = section 内容
# 输出: 每行一个列表项内容（去掉 "- " 前缀）
extract_list_items() {
    local content
    content="$(cat)"
    # 匹配以 "- " 开头且后面有非空白内容的行
    echo "$content" | grep "^\- " | sed 's/^\- //' | grep -v "^[${SPC_TAB}]*$" || true
}

# 检查文本是否包含问题关键词（中英文）
# 参数: stdin = 文本
# 返回: 0 = 包含, 1 = 不包含
has_problem_keywords() {
    local text
    text="$(cat)"
    # 使用 -E 单模式（| 分隔）代替多个 -e，避免 msys grep 在 -i 模式下
    # 处理多个 -e 参数时崩溃的已知 bug
    if echo "$text" | grep -q -i -E "失败|不可用|降级|超时|误判|错误|fail|unavailable|degrad|timeout|error|break|broken|bug|crash|missing" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 检查 section 是否有实质性内容（不只是模板提示语）
# 参数: stdin = section 内容
# 返回: 0 = 有实质内容, 1 = 无实质内容
has_substantive_content() {
    local content
    content="$(cat)"
    # 移除空行和纯标点行
    local cleaned
    cleaned=$(echo "$content" | grep -v "^[${SPC_TAB}]*$" | grep -v "^[-=#>*_${SPC_TAB}]*$" || true)
    if [ -z "$cleaned" ]; then
        return 1
    fi
    # 移除模板提示语（中英文）
    cleaned=$(echo "$cleaned" | grep -v "Should this become" | grep -v "skill, checklist" | grep -v "AGENTS.md update" | grep -v "是否应该成为" | grep -v "技能、检查清单" || true)
    if [ -z "$cleaned" ]; then
        return 1
    fi
    return 0
}

# 从失败项文本中自动生成 tags
# 参数: $1 = 失败项文本
# 输出: 空格分隔的 tag 列表
auto_generate_tags() {
    local text="$1"
    local tags=""

    # 确定性关键词映射（中英文）
    # 使用 grep -q -i -E "A|B|C" 单模式，避免 msys grep 多 -e 崩溃 bug
    if echo "$text" | grep -q -i -E "超时|timeout|timed out"; then
        tags="$tags timeout"
    fi
    if echo "$text" | grep -q -i -E "降级|fallback|degrad"; then
        tags="$tags degradation"
    fi
    if echo "$text" | grep -q -i -E "通信|交接|handoff|communicat"; then
        tags="$tags handoff"
    fi
    if echo "$text" | grep -q -i -E "审查|review|code-review"; then
        tags="$tags review"
    fi
    if echo "$text" | grep -q -i -E "门禁|gate|checkpoint|gate-check"; then
        tags="$tags gate"
    fi
    if echo "$text" | grep -q -i -E "规格|spec|OpenSpec|偏离"; then
        tags="$tags spec-drift"
    fi
    if echo "$text" | grep -q -i -E "重复|recur|repeat|再次"; then
        tags="$tags recurrence"
    fi
    if echo "$text" | grep -q -i -E "MCP|mcp"; then
        tags="$tags mcp"
    fi
    if echo "$text" | grep -q -i -E "Codex|codex"; then
        tags="$tags codex"
    fi
    if echo "$text" | grep -q -i -E "Claude|claude"; then
        tags="$tags claude"
    fi
    if echo "$text" | grep -q -i -E "工具|tool|skill"; then
        tags="$tags tooling"
    fi
    if echo "$text" | grep -q -i -E "测试|test|verify|验证"; then
        tags="$tags testing"
    fi
    if echo "$text" | grep -q -i -E "权限|permission|auth"; then
        tags="$tags auth"
    fi
    if echo "$text" | grep -q -i -E "文件|file|artifact|产物"; then
        tags="$tags artifacts"
    fi
    if echo "$text" | grep -q -i -E "模板|template"; then
        tags="$tags templates"
    fi
    if echo "$text" | grep -q -i -E "配置|config|setting"; then
        tags="$tags config"
    fi

    # 去重并返回
    echo "$tags" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed "s/^[${SPC_TAB}]*//;s/[${SPC_TAB}]*$//"
}

# 将 tags 列表格式化为 YAML 数组字符串
# 参数: $1 = 空格分隔的 tags
# 输出: "[tag1, tag2, tag3]"
format_tags_yaml() {
    local tags_str="$1"
    local result=""
    local first=true
    for tag in $tags_str; do
        [ -z "$tag" ] && continue
        if [ "$first" = true ]; then first=false; else result+=", "; fi
        result+="$tag"
    done
    if [ -z "$result" ]; then
        echo "[]"
    else
        echo "[$result]"
    fi
}

# 将多行文本缩进 2 空格（用于填充到 Markdown section 中）
indent_text() {
    sed 's/^/  /'
}

# 从一段文本生成一句摘要（取第一句，截断到 80 字符）
generate_summary() {
    local text="$1"
    # 取第一行（或第一句）
    local line
    line=$(echo "$text" | head -1 | sed "s/^[${SPC_TAB}]*//;s/[${SPC_TAB}]*$//")
    if [ -z "$line" ]; then
        line="（无详细描述）"
    fi
    # 截断到 80 字符
    if [ "${#line}" -gt 80 ]; then
        line="${line:0:77}..."
    fi
    echo "$line"
}

# ---- 核心函数 ---------------------------------------------------------------

# 检查某个功能是否已有提取的 Lesson
# 参数: $1 = feature-id
# 返回: 0 = 已有 Lesson, 1 = 没有
has_existing_lessons() {
    local fid="$1"
    local lesson_dir="$LESSONS_DIR/$fid"
    if [ -d "$lesson_dir" ] && ls "$lesson_dir"/lesson-*.md >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# 获取某个功能目录下已有 Lesson 的最大序号
# 参数: $1 = feature-id
# 输出: 数字（如 0 表示没有）
get_max_lesson_number() {
    local fid="$1"
    local lesson_dir="$LESSONS_DIR/$fid"
    local max=0
    if [ -d "$lesson_dir" ]; then
        for f in "$lesson_dir"/lesson-*.md; do
            [ -e "$f" ] || continue
            local basename
            basename=$(basename "$f" .md)
            local num
            num=$(echo "$basename" | sed 's/^lesson-//' | grep -o '^[0-9]*')
            if [ -n "$num" ] && [ "$num" -gt "$max" ] 2>/dev/null; then
                max=$num
            fi
        done
    fi
    echo "$max"
}

# 为单个功能生成 Lesson 草稿
# 参数: $1 = feature-id
# 返回: 0 = 成功, 1 = 跳过
generate_lessons_for_feature() {
    local fid="$1"
    local retro_file="$FEATURES_DIR/$fid/07-task-retro.md"

    # 检查 retro 文件是否存在
    if [ ! -f "$retro_file" ]; then
        log_warn "功能 '$fid' 没有 07-task-retro.md，跳过"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # 检查是否已有提取的 Lesson（除非 --force）
    if [ "$FORCE" = false ] && has_existing_lessons "$fid"; then
        log_info "功能 '$fid' 已有 Lesson 文件，跳过（使用 --force 覆盖）"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        EXIT_CODE=1
        return 1
    fi

    # --force 模式：清空已有 Lesson
    if [ "$FORCE" = true ] && has_existing_lessons "$fid"; then
        log_info "功能 '$fid': --force 模式，移除已有 Lesson 文件"
        rm -f "$LESSONS_DIR/$fid"/lesson-*.md
    fi

    log_info "处理功能: $fid"

    # ========================================
    # Step 1: 提取 "What Failed Or Slowed Us Down" / "失败或拖慢进度的事"
    # ========================================
    local failed_section
    failed_section=$(extract_section "$retro_file" "What Failed Or Slowed Us Down" "失败或拖慢进度的事" "What Failed" "失败")
    local failed_items=()
    local item
    while IFS= read -r item; do
        [ -z "$item" ] && continue
        # 跳过纯模板占位符（只有 "- " 没有实质内容的行）
        local trimmed
        trimmed=$(echo "$item" | sed "s/^[${SPC_TAB}]*//;s/[${SPC_TAB}]*$//")
        if [ -n "$trimmed" ]; then
            failed_items+=("$trimmed")
        fi
    done < <(echo "$failed_section" | extract_list_items)

    # ========================================
    # Step 2: 提取 "Tool / Agent Notes" / "工具/Agent 备注"
    # ========================================
    local tool_section
    tool_section=$(extract_section "$retro_file" "Tool / Agent Notes" "工具/Agent 备注" "Tool" "工具")
    local problem_notes=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if echo "$line" | has_problem_keywords; then
            local cleaned
            cleaned=$(echo "$line" | sed 's/^[- ]*//' | sed "s/^[${SPC_TAB}]*//;s/[${SPC_TAB}]*$//")
            [ -n "$cleaned" ] && problem_notes+="- $cleaned"$'\n'
        fi
    done < <(echo "$tool_section")

    # ========================================
    # Step 3: 提取 "Reusable Pattern Found" / "可复用模式"
    # ========================================
    local pattern_section
    pattern_section=$(extract_section "$retro_file" "Reusable Pattern Found" "可复用模式")
    local has_pattern=false
    if echo "$pattern_section" | has_substantive_content; then
        has_pattern=true
    fi

    # ========================================
    # Step 4: 提取 "Knowledge To Carry Forward" / "传递知识"
    # ========================================
    local knowledge_section
    knowledge_section=$(extract_section "$retro_file" "Knowledge To Carry Forward" "传递知识" "Knowledge")

    # ========================================
    # Step 5: 如果没有失败项也没有可复用模式 → 无需生成 Lesson
    # ========================================
    if [ "${#failed_items[@]}" -eq 0 ] && [ "$has_pattern" = false ]; then
        log_info "功能 '$fid': retro 中没有失败项或可复用模式，无 Lesson 生成"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 0
    fi

    # ========================================
    # Step 6: 生成 Lesson 文件
    # ========================================
    ensure_dir "$LESSONS_DIR/$fid"
    local seq
    seq=$(get_max_lesson_number "$fid")

    local now
    now=$(iso_timestamp)

    # 收集本功能所有 tags（用于跨功能 Pattern 检测）
    local all_feature_tags=""

    # 辅助函数：写入单个 Lesson 文件
    write_lesson_file() {
        local lesson_num="$1"
        local lesson_id="LSN-${fid}-$(printf '%03d' "$lesson_num")"
        local summary="$2"
        local what_happened="$3"
        local why_happened="$4"
        local impact="$5"
        local learned="$6"
        local should_change="$7"
        local tags_str="$8"

        local tags_yaml
        tags_yaml=$(format_tags_yaml "$tags_str")

        local file_path="$LESSONS_DIR/$fid/lesson-$(printf '%03d' "$lesson_num").md"

        cat > "$file_path" <<LESSONEOF
---
lessonId: ${lesson_id}
featureId: ${fid}
taskId: feature-level
source: 07-task-retro.md
extractedAt: ${now}
status: draft
severity: P3
reviewedBy: null
reviewedAt: null
tags: ${tags_yaml}
relatedGates: []
relatedPatterns: []
promotedToPattern: null
---

# ${summary}

## 发生了什么

${what_happened}

## 为什么会发生

${why_happened}

## 影响

${impact}

## 学到了什么

${learned}

## 应该改变什么

${should_change}

## 关联 Pattern 候选

- 关联已有 Pattern: 无
- 建议新 Pattern: 无
- 建议理由: （待人工审阅时填写）
LESSONEOF

        log_info "  创建: lesson-$(printf '%03d' "$lesson_num").md (${lesson_id})"
        CREATED_COUNT=$((CREATED_COUNT + 1))
    }

    # ---- 为每个失败项生成一个 Lesson ----
    local failing_tags=""
    for i in "${!failed_items[@]}"; do
        seq=$((seq + 1))
        local fail_text="${failed_items[$i]}"
        local lesson_tags
        lesson_tags=$(auto_generate_tags "$fail_text")
        failing_tags+=" $lesson_tags"

        # 摘要：从失败项取第一句
        local summary
        summary=$(generate_summary "$fail_text")

        # 发生了什么：直接使用失败项描述
        local what_happened
        what_happened="> ${fail_text}"

        # 为什么会发生：来自 Tool / Agent Notes 中匹配问题关键词的条目
        local why_happened
        if [ -n "$problem_notes" ]; then
            why_happened="> 以下工具/Agent 备注中发现了问题线索：\n>\n$(echo "$problem_notes" | sed 's/^/> /' | sed 's/^> $/>/')"
        else
            why_happened="> （Tool / Agent Notes 中未发现匹配的问题关键词，待人工补充）"
        fi

        # 影响：待人工填写
        local impact
        impact="> （待人工审阅时填写——延误了多久？增加了几次返工？）"

        # 学到了什么：来自 Knowledge To Carry Forward
        local learned
        if [ -n "$knowledge_section" ]; then
            local k_clean
            k_clean=$(echo "$knowledge_section" | sed "/^[${SPC_TAB}]*$/d" | head -5)
            if [ -n "$k_clean" ]; then
                learned="$(echo "$k_clean" | sed 's/^/> /')"
            else
                learned="> （Knowledge To Carry Forward 为空，待人工补充）"
            fi
        else
            learned="> （Knowledge To Carry Forward 为空，待人工补充）"
        fi

        # 应该改变什么：待人工填写
        local should_change
        should_change="- [ ] （待人工审阅时填写——修改哪个文件？增加哪个检查？）"

        write_lesson_file "$seq" "$summary" "$what_happened" "$why_happened" "$impact" "$learned" "$should_change" "$lesson_tags"
    done

    # ---- 若 Reusable Pattern Found 有实质内容，额外生成一个 Lesson ----
    if [ "$has_pattern" = true ]; then
        seq=$((seq + 1))
        local pattern_text
        pattern_text=$(echo "$pattern_section" | sed "/^[${SPC_TAB}]*$/d" | grep -v "Should this become" | grep -v "skill, checklist" | grep -v "AGENTS.md" | head -10)

        local p_tags
        p_tags=$(auto_generate_tags "$pattern_text")
        failing_tags+=" $p_tags"

        local p_summary
        p_summary="可复用模式: $(generate_summary "$pattern_text")"

        local p_what
        p_what="> 在本次功能开发中识别到一个可复用模式：\n>\n$(echo "$pattern_text" | sed 's/^/> /')"

        local p_why
        if [ -n "$problem_notes" ]; then
            p_why="> 以下工具/Agent 备注提供了模式上下文：\n>\n$(echo "$problem_notes" | sed 's/^/> /' | sed 's/^> $/>/')"
        else
            p_why="> （待人工补充——为什么这个模式值得提取？）"
        fi

        local p_impact
        p_impact="> （待人工审阅时填写——此模式如果不提取，预计影响哪些后续功能？）"

        local p_learned
        if [ -n "$knowledge_section" ]; then
            local k_clean
            k_clean=$(echo "$knowledge_section" | sed "/^[${SPC_TAB}]*$/d" | head -5)
            if [ -n "$k_clean" ]; then
                p_learned="$(echo "$k_clean" | sed 's/^/> /')"
            else
                p_learned="> （Knowledge To Carry Forward 为空，待人工补充）"
            fi
        else
            p_learned="> （Knowledge To Carry Forward 为空，待人工补充）"
        fi

        local p_change
        p_change="- [ ] 评估是否应晋升此模式为 Pattern（需 ≥2 个不同功能的 Lesson 支持）"
        p_change+=$'\n'"- [ ] 若晋升，在 workflow/experience/patterns/ 下创建 Pattern 文件"

        write_lesson_file "$seq" "$p_summary" "$p_what" "$p_why" "$p_impact" "$p_learned" "$p_change" "$p_tags"
    fi

    # 记录本功能的 tags
    if [ -n "$failing_tags" ]; then
        # 去重
        local unique_tags
        unique_tags=$(echo "$failing_tags" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed "s/^[${SPC_TAB}]*//;s/[${SPC_TAB}]*$//")
        FEATURE_TAGS["$fid"]="$unique_tags"
    fi

    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    return 0
}

# ---- 索引管理 ---------------------------------------------------------------

# 解析单个 Lesson 文件的 YAML frontmatter 获取指定字段
# 参数: $1 = 文件路径, $2 = 字段名
# 输出: 字段值
get_lesson_field() {
    local file="$1"
    local field="$2"
    # 匹配 YAML frontmatter 中的 key: value
    local val
    val=$(grep "^${field}:" "$file" 2>/dev/null | head -1 | sed "s/^${field}:[${SPC_TAB}]*//" | sed 's/^"//;s/"$//' | sed 's/^\[//;s/\]$//')
    echo "$val"
}

# 获取 Lesson 文件的标题（第一个 # 行）
get_lesson_title() {
    local file="$1"
    local title
    title=$(grep "^# " "$file" 2>/dev/null | head -1 | sed 's/^# //' | sed "s/^[${SPC_TAB}]*//;s/[${SPC_TAB}]*$//")
    if [ -z "$title" ]; then
        title="（无标题）"
    fi
    echo "$title"
}

# 重新生成 _index.md
rebuild_index() {
    log_info "重建索引: $INDEX_FILE"

    local now
    now=$(iso_timestamp)

    # 统计
    local total=0 draft=0 reviewed=0 promoted=0 archived=0
    local index_rows=""
    local warnings=""

    # 遍历所有 lesson 文件
    local lesson_files=()
    while IFS= read -r -d '' f; do
        lesson_files+=("$f")
    done < <(find "$LESSONS_DIR" -name "lesson-*.md" -type f -print0 2>/dev/null || true)

    for lf in "${lesson_files[@]}"; do
        [ -e "$lf" ] || continue
        total=$((total + 1))

        local lesson_id fid summary severity tags_str status related_pattern

        lesson_id=$(get_lesson_field "$lf" "lessonId")
        fid=$(get_lesson_field "$lf" "featureId")
        severity=$(get_lesson_field "$lf" "severity")
        tags_str=$(get_lesson_field "$lf" "tags")
        status=$(get_lesson_field "$lf" "status")
        related_pattern=$(get_lesson_field "$lf" "promotedToPattern")

        summary=$(get_lesson_title "$lf")

        # 默认值
        [ -z "$lesson_id" ] && lesson_id="LSN-unknown"
        [ -z "$fid" ] && fid="unknown"
        [ -z "$severity" ] && severity="P3"
        [ -z "$status" ] && status="draft"
        [ -z "$related_pattern" ] || [ "$related_pattern" = "null" ] && related_pattern="-"
        [ -z "$tags_str" ] || [ "$tags_str" = "[]" ] && tags_str="-"

        # 统计
        case "$status" in
            draft)    draft=$((draft + 1)) ;;
            reviewed) reviewed=$((reviewed + 1)) ;;
            promoted) promoted=$((promoted + 1)) ;;
            archived) archived=$((archived + 1)) ;;
        esac

        # 构建表格行
        index_rows+="| $lesson_id | $fid | $summary | $severity | $tags_str | $status | $related_pattern |"$'\n'

        # 检查 stale 条件：draft 超过 60 天
        if [ "$status" = "draft" ]; then
            local extracted_at
            extracted_at=$(get_lesson_field "$lf" "extractedAt")
            if [ -n "$extracted_at" ] && [ "$extracted_at" != "null" ]; then
                # 简单比较：提取日期格式 2026-06-16T...
                local extract_date
                extract_date=$(echo "$extracted_at" | cut -dT -f1)
                if [ -n "$extract_date" ]; then
                    local current_date
                    current_date=$(date +"%Y-%m-%d" 2>/dev/null || date +"%Y-%m-%d")
                    # 使用日期差（近似：按天数计算）
                    local extract_epoch current_epoch
                    extract_epoch=$(date -d "$extract_date" +%s 2>/dev/null || echo "0")
                    current_epoch=$(date -d "$current_date" +%s 2>/dev/null || echo "0")
                    if [ "$extract_epoch" != "0" ] && [ "$current_epoch" != "0" ]; then
                        local diff_days=$(( (current_epoch - extract_epoch) / 86400 ))
                        if [ "$diff_days" -gt 60 ]; then
                            warnings+="- \`$lesson_id\`: draft 超过 60 天未审阅（创建于 $extract_date）"$'\n'
                        fi
                    fi
                fi
            fi
        fi
    done

    # 构建索引内容
    local index_content
    index_content=$(cat <<INDEXEOF
# Lessons 索引

> 自动生成于 \`${now}\`
> 总计: ${total} 个（draft: ${draft}, reviewed: ${reviewed}, promoted: ${promoted}, archived: ${archived}）

| ID | 功能 | 摘要 | 严重度 | Tags | 状态 | 关联 Pattern |
|----|------|------|--------|------|------|-------------|
INDEXEOF
)

    if [ "$total" -gt 0 ]; then
        index_content+=$'\n'"$index_rows"
    else
        index_content+=$'\n'"| （暂无 Lesson） |||||||"$'\n'
    fi

    if [ -n "$warnings" ]; then
        index_content+=$'\n'"## Warnings"$'\n'$'\n'
        index_content+="> 以下 Lesson 需要关注："$'\n'$'\n'
        index_content+="$warnings"
    fi

    ensure_dir "$LESSONS_DIR"
    echo "$index_content" > "$INDEX_FILE"
    log_info "索引已更新: $total 个 Lesson"
}

# ---- Pattern 候选检测 --------------------------------------------------------

# 检测跨功能 tags 交集，提示可能创建 Pattern
detect_pattern_candidates() {
    local feature_ids=()
    while IFS= read -r -d '' dir; do
        local fid
        fid=$(basename "$dir")
        feature_ids+=("$fid")
    done < <(find "$LESSONS_DIR" -maxdepth 1 -type d ! -name "lessons" ! -name "." -print0 2>/dev/null || true)

    if [ "${#feature_ids[@]}" -lt 2 ]; then
        return 0
    fi

    # 对每个功能收集 tags
    declare -A feature_tag_set
    for fid in "${feature_ids[@]}"; do
        local all_tags=""
        local lesson_dir="$LESSONS_DIR/$fid"
        if [ -d "$lesson_dir" ]; then
            for lf in "$lesson_dir"/lesson-*.md; do
                [ -e "$lf" ] || continue
                local tags_str
                tags_str=$(get_lesson_field "$lf" "tags")
                [ -z "$tags_str" ] || [ "$tags_str" = "[]" ] && continue
                # 移除 YAML 数组格式的方括号和引号
                tags_str=$(echo "$tags_str" | sed 's/^\[//;s/\]$//;s/"//g;s/,/ /g')
                all_tags+=" $tags_str"
            done
        fi
        # 去重
        all_tags=$(echo "$all_tags" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed "s/^[${SPC_TAB}]*//;s/[${SPC_TAB}]*$//")
        feature_tag_set["$fid"]="$all_tags"
    done

    # 两两比较
    local found_pattern_candidates=false
    local n=${#feature_ids[@]}
    for ((i = 0; i < n; i++)); do
        for ((j = i + 1; j < n; j++)); do
            local fid_a="${feature_ids[$i]}"
            local fid_b="${feature_ids[$j]}"
            local tags_a="${feature_tag_set[$fid_a]}"
            local tags_b="${feature_tag_set[$fid_b]}"

            [ -z "$tags_a" ] && continue
            [ -z "$tags_b" ] && continue

            # 计算交集
            local intersection=()
            for tag_a in $tags_a; do
                for tag_b in $tags_b; do
                    if [ "$tag_a" = "$tag_b" ]; then
                        intersection+=("$tag_a")
                    fi
                done
            done

            if [ "${#intersection[@]}" -ge 2 ]; then
                if [ "$found_pattern_candidates" = false ]; then
                    echo ""
                    echo "╔══════════════════════════════════════════════════════════════╗"
                    echo "║  💡 建议创建 Pattern                                         ║"
                    echo "╚══════════════════════════════════════════════════════════════╝"
                    echo ""
                    found_pattern_candidates=true
                fi
                local intersect_str
                intersect_str=$(printf '%s, ' "${intersection[@]}" | sed 's/, $//')
                echo "  功能 [$fid_a] 与 [$fid_b] 共享 ≥2 个 tags: [$intersect_str]"
                echo "  → 建议检查是否应创建跨功能 Pattern"
                echo ""
            fi
        done
    done
}

# ---- --check 模式 -----------------------------------------------------------

# 检查是否有未提取的 retro
check_unprocessed_retros() {
    log_info "检查未提取的 retro..."

    local unprocessed=()
    local feature_dirs=()

    while IFS= read -r -d '' dir; do
        feature_dirs+=("$dir")
    done < <(find "$FEATURES_DIR" -maxdepth 1 -type d ! -name "features" ! -name "." -print0 2>/dev/null || true)

    for dir in "${feature_dirs[@]}"; do
        [ -d "$dir" ] || continue
        local fid
        fid=$(basename "$dir")
        local retro_file="$dir/07-task-retro.md"

        # 没有 retro → 跳过
        if [ ! -f "$retro_file" ]; then
            continue
        fi

        # 检查 retro 是否为空内容（只有模板骨架）
        local retro_size
        retro_size=$(wc -c < "$retro_file" 2>/dev/null || echo "0")
        retro_size=$(echo "$retro_size" | tr -d '[:space:]')
        if [ "${retro_size:-0}" -lt 50 ]; then
            continue
        fi

        # 检查是否已有 Lesson
        if ! has_existing_lessons "$fid"; then
            unprocessed+=("$fid")
            continue
        fi

        # 检查 retro 是否比最新的 Lesson 更新
        local lesson_dir="$LESSONS_DIR/$fid"
        local newest_lesson
        newest_lesson=$(ls -t "$lesson_dir"/lesson-*.md 2>/dev/null | head -1)
        if [ -n "$newest_lesson" ] && [ "$retro_file" -nt "$newest_lesson" ]; then
            unprocessed+=("$fid (retro 已更新，需重新提取)")
        fi
    done

    if [ "${#unprocessed[@]}" -gt 0 ]; then
        echo ""
        echo "发现 ${#unprocessed[@]} 个未提取的 retro:"
        for item in "${unprocessed[@]}"; do
            echo "  - $item"
        done
        echo ""
        echo "运行以下命令提取:"
        echo "  bash $SCRIPT_NAME --all"
        echo ""
        exit 3
    else
        echo ""
        echo "所有 retro 均已提取。"
        echo ""
        exit 0
    fi
}

# ---- 参数解析 ---------------------------------------------------------------

parse_args() {
    if [ $# -eq 0 ]; then
        usage
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                ;;
            --all)
                MODE="all"
                shift
                ;;
            --check)
                MODE="check"
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            -*)
                log_error "未知选项: $1"
                usage
                ;;
            *)
                if [ -z "$FEATURE_ID" ]; then
                    FEATURE_ID="$1"
                    MODE="single"
                else
                    log_error "多余的参数: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    # 验证
    if [ "$MODE" = "check" ] && [ "$FORCE" = true ]; then
        log_error "--check 模式不支持 --force（--check 只读，不生成文件）"
        exit 2
    fi

    if [ -z "$MODE" ]; then
        log_error "请指定 <feature-id>、--all 或 --check"
        usage
    fi
}

# ---- 主流程 -----------------------------------------------------------------

main() {
    parse_args "$@"

    # 确保 features 目录存在
    if [ ! -d "$FEATURES_DIR" ]; then
        log_error "features 目录不存在: $FEATURES_DIR"
        exit 2
    fi

    # --check 模式
    if [ "$MODE" = "check" ]; then
        check_unprocessed_retros
        exit 0
    fi

    # 收集要处理的功能列表
    local feature_ids=()
    if [ "$MODE" = "all" ]; then
        while IFS= read -r -d '' dir; do
            local fid
            fid=$(basename "$dir")
            feature_ids+=("$fid")
        done < <(find "$FEATURES_DIR" -maxdepth 1 -type d ! -name "features" ! -name "." -print0 2>/dev/null || true)

        if [ "${#feature_ids[@]}" -eq 0 ]; then
            log_warn "workflow/features/ 下没有功能目录"
            exit 0
        fi
        log_info "扫描到 ${#feature_ids[@]} 个功能目录"
    else
        feature_ids+=("$FEATURE_ID")
    fi

    # 处理每个功能
    for fid in "${feature_ids[@]}"; do
        generate_lessons_for_feature "$fid" || true
    done

    # 重建索引
    rebuild_index

    # 跨功能 Pattern 候选检测
    if [ "$MODE" = "all" ] || [ "${#feature_ids[@]}" -ge 2 ]; then
        detect_pattern_candidates
    fi

    # 汇总
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  提取完成"
    echo "  - 已处理: $PROCESSED_COUNT 个功能"
    echo "  - 已跳过: $SKIPPED_COUNT 个功能"
    echo "  - 已创建: $CREATED_COUNT 个 Lesson 草稿"
    echo "═══════════════════════════════════════════════"
    echo ""
    echo "下一步:"
    echo "  1. 审阅各 Lesson 文件，修正 severity、tags"
    echo "  2. 将 status: draft 改为 status: reviewed"
    echo "  3. 若有 ≥2 个相关 Lesson，考虑晋升为 Pattern"
    echo ""

    exit $EXIT_CODE
}

main "$@"
