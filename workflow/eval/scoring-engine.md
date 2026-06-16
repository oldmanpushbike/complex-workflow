# 确定性评分引擎 (Deterministic Scoring Engine)

> 核心原则：宁要可复现的粗糙分，不要会漂移的精准分。
> 3 次跑分 hash 完全一致。零 LLM 调用。只读取 feature-state.json 和产物文件，不做任何推断。
> 所有计算均为闭式公式，手工验算可行。

---

## 架构概览

```
feature-state.json（单个功能）
        │
        ▼
┌──────────────────────────┐
│  7 维评分引擎              │
│  - 全确定性公式            │
│  - 零 LLM 调用            │
│  - 纯算术 + 枚举匹配       │
│  - 文件系统 stat 检查      │
└──────────┬───────────────┘
           │
           ▼
┌──────────────────────────┐
│  评分输出 score.json       │
│  - 每个维度 0-100 分       │
│  - 加权总分                │
│  - 基线对比                │
│  - 确定性 Hash             │
│  - 警告列表                │
└──────────┬───────────────┘
           │
           ▼
┌──────────────────────────┐
│  下游消费者                │
│  - dashboard.html         │
│  - gate-check.sh --score  │
│  - CI 质量门禁             │
│  - 经验管道触发             │
│  - baselines.json 更新    │
└──────────────────────────┘
```

---

## 1. 七维评分体系

每个维度产生一个 0-100 的整数分数。所有计算仅依赖 `feature-state.json` 的结构化字段和产物文件的存在性/大小。公式纯算术，不含任何机器学习推断。

### 权重总览

| 序号 | 维度 | 权重 | 核心度量 |
|------|------|------|----------|
| D1 | 流程完整性 | 22% | 所有门禁产物是否存在、门禁是否通过 |
| D2 | 审查质量 | 22% | grill-me + review 发现数、P0/P1 覆盖率 |
| D3 | 降级频率 | 15% | single-agent 模式占比、降级事件严重度 |
| D4 | 人工响应延迟 | 10% | 人类审批的平均响应时间 |
| D5 | 经验沉淀率 | 12% | retro → pattern 转化、ADR 决策可追溯 |
| D6 | 重试成功率 | 10% | 反馈循环修正成功率 |
| D7 | 文档健康度 | 9% | ADR / retro 文件存在性和内容完整度 |

---

### 1.1 D1 流程完整性 (Process Integrity) — 权重 22%

**度量什么：** 工作流的每个门禁是否有对应的产物文件，且门禁状态为已通过或已豁免。

**数据来源：**
- `feature-state.json → gates[]` 数组中每个 gate 对象的 `status`、`artifacts` 字段
- 功能文件夹下的实际产物文件（文件系统检查）

**确定性公式：**

```
Let applicable_gates = { gate in gates[]
    where feature has reached this gate's state phase }
    // 「已到达」定义：currentState 对应的 S 编号 >= 该门禁对应的状态编号
    // Gate 1 → S1, Gate 2 → S2, Gate 3 → S3/S4, Gate 4 → S4,
    //   Gate 5 → S6, Gate 6 → S7, Gate 7 → S8

For each gate in applicable_gates:
    status_ok = (gate.status == "passed" OR gate.status == "skipped")
    artifacts_ok = ALL artifacts in gate.artifacts[] satisfy:
        file_exists(featureDir + "/" + artifactPath)
        AND file_size(featureDir + "/" + artifactPath) >= minSize(artifactPath)

    gate_score = 1  if (status_ok AND artifacts_ok)
    gate_score = 0  otherwise

ProcessIntegrity = round(sum(gate_score) / count(applicable_gates) * 100)
```

**产物最小大小阈值（与 gate-check.sh 同源）：**

| 产物文件 | minSize (bytes) |
|----------|-----------------|
| 01-openspec-proposal.md | 500 |
| 02-grill-me-report.md | 300 |
| 03-task-skill-map.md | 300 |
| 04-implementation-plan.md | 100 |
| reviews/*.md（目录下至少 1 个 .md） | 200 |
| 05-verification-log.md | 100 |
| 06-adr.md | 100 |
| 07-task-retro.md | 100 |

**特殊规则：**

- `reviews/` 目录检查：使用 glob 匹配 `reviews/*.md`，至少存在 1 个文件且其中至少 1 个 >= 200 bytes
- 若 `mode == "single-agent"`：reviews/ 只需 1 份 .md 文件即可视为 artifacts_ok
- 若 `mode == "dual-agent"`：期望 2 份（codex-review.md + claude-review.md），但 1 份即算 artifacts_ok（仅影响 artifacts_ok 的布尔结果）
- 若 `gate.status == "pending"` 且 currentState 尚未推进到该门禁：该门禁不计入 `applicable_gates`
- 若功能在 S9（已归档）且存在 `failed` 门禁且未豁免 → 直接返回 0（归档态不允许残留失败门禁）

**可复现性保证：** `status` 枚举值精确匹配，`test -f` 检查存在性，`wc -c` 读大小，纯文件系统操作。

---

### 1.2 D2 审查质量 (Review Quality) — 权重 22%

**度量什么：** grill-me 和 code review 是否发现了实质性问题，P0/P1 覆盖率是否充足。

**数据来源：**
- `feature-state.json → gates[].findings[]`（来自 gate-2 grill-me 和 gate-5 审查）
- 具体的 source 字段区分 grill-me 和 code-review
- `severity` 字段取值为 `P0 | P1 | P2 | P3`

**确定性公式：**

```
// 收集所有审查类 finding
Let G = 所有 gate.findings[] 中 source == "grill-me" 的 finding
Let R = 所有 gate.findings[] 中 source == "code-review" 的 finding
Let A = G ∪ R  （全部审查发现）

Let F = count(A)                                    // 总发现数
Let P0 = count(A where severity == "P0")            // P0 阻断性问题
Let P1 = count(A where severity == "P1")            // P1 功能问题
Let P2 = count(A where severity == "P2")            // P2 技术债务
Let P3 = count(A where severity == "P3")            // P3 改进建议

// 若完全无发现
If F == 0:
    ReviewQuality = 0   // 零发现 = 审查形同虚设

// 若有发现
If F > 0:
    // 子维度 1：发现密度（体现审查的细致程度）
    density = min(F * 10, 50)           // 5 个发现即满 50 分

    // 子维度 2：严重度加权分（P0 权重最高，体现审查是否发现了关键问题）
    severity = min(P0 * 12 + P1 * 6 + P2 * 2 + P3 * 1, 50)

    // 子维度 3：来源覆盖
    has_grill = (count(G) > 0) ? 1 : 0
    has_review = (count(R) > 0) ? 1 : 0
    coverage_bonus = (has_grill + has_review) * 5   // 共 0/5/10

    raw = density + severity + coverage_bonus

    // 若为 single-agent 模式，自审可信度折扣
    IF mode == "single-agent":
        ReviewQuality = round(raw * 0.75)
    ELSE:
        ReviewQuality = min(100, raw)
```

**计算示例：**

- 0 个 finding → 0 分（审查未执行或草率）
- 1 个 P1（grill-me）→ density 10 + severity 6 + coverage 5 = 21 分
- 3 个 finding：1 P0 + 1 P1 + 1 P2（均有 grill-me + review）→ density 30 + severity 20 + coverage 10 = 60 分
- 6 个 finding：2 P0 + 2 P1 + 1 P2 + 1 P3 → density 50 + severity 39 + coverage 10 = 99 分（封顶100）
- 同上但在 single-agent 模式 → 99 × 0.75 ≈ 74 分

**可复现性保证：** finding 数量是 count，severity 是 schema 枚举值计数，source 枚举精确匹配，纯算术。

---

### 1.3 D3 降级频率 (Degradation Frequency) — 权重 15%

**度量什么：** 工作流在 single-agent 模式下的运行占比，以及降级事件的严重程度。

**数据来源：**
- `feature-state.json → mode` 字段
- `feature-state.json → fallbackEvents[]` 数组
- `feature-state.json → stateHistory[]` 数组

**确定性公式：**

```
Let E = count(fallbackEvents)                        // 降级事件总数
Let SA = count(fallbackEvents where resolution == "single-agent-mode")  // 切到单 Agent 的次数

// 权重矩阵（每个 eventType 对应一个严重度权重）
Let severity_weight = sum over fallbackEvents:
    event → weight mapping:
        "orchestrator_unreachable"  → 5
        "human_unavailable"         → 5
        "agent_disagreement"        → 4
        "multiple_tool_failures"    → 4
        "challenger_unreachable"    → 3
        "reviewer_unreachable"      → 3
        "grill_unavailable"         → 2
        "tests_unavailable"         → 2
        "superpowers_unavailable"   → 2
        "partial_grill"             → 1
        "partial_review"            → 1
        "openspec_unavailable"      → 1
        "find_skill_unavailable"    → 1
        "mcp_unavailable"           → 1
        "network_unavailable"       → 1

// 累计扣分
penalty = min(severity_weight * 6, 90)    // 每点 severity 扣 6 分，上限扣 90
single_agent_penalty = SA * 5              // 每切一次单 Agent 模式额外扣 5 分

If E == 0:
    DegradationFrequency = 100
Else:
    DegradationFrequency = max(10, 100 - penalty - single_agent_penalty)
```

**说明：**
- 0 次降级事件 → 满分 100
- orchestrator_unreachable + human_unavailable (severity=10) → 扣 60 + 若有 SA 再扣 5-10 = 最高扣 70，剩 30
- 最低分 10（不会出现 0 分，因为降级本身不是「错误」，是环境约束）

**可复现性保证：** eventType 是 schema 枚举值，权重表硬编码，resolution 枚举值精确匹配。

---

### 1.4 D4 人工响应延迟 (Human Response Latency) — 权重 10%

**度量什么：** 人类在 Checkpoint 处做出决策的平均响应时间。不是越快越好——该快的快（阻塞型门禁），该慢的不扣分（设计决策允许从容思考）。

**数据来源：**
- `feature-state.json → humanDecisions[]` 数组中的 `madeAt` 字段
- `feature-state.json → gates[].enteredAt`（门禁首次进入时间）

**确定性公式：**

```
Let HD = humanDecisions[]

If HD is empty or count(HD) == 0:
    // 无人类决策：无法评估延迟
    // 需要区分「不需要人类」和「缺少数据」
    If mode == "dual-agent" AND count(gates where gate.status in ["passed","skipped"]) >= 5:
        HumanResponseLatency = 80  // 流程顺利进行，人类未阻碍
    Else:
        HumanResponseLatency = 50  // 中性分，数据不足

If HD is not empty:
    For each decision d in HD:
        // 找到对应门禁
        gate = gates[] where gate.gateId == d.gateId
        If gate exists AND gate.enteredAt exists:
            latency_hours = (d.madeAt - gate.enteredAt) in hours
        Else:
            latency_hours = null  // 无法计算，跳过此决策

        // 单决策评分
        If latency_hours == null:
            decision_score = 50  // 无法评估，给中性分
        Else:
            If     latency_hours <= 1    → decision_score = 100
            Else if latency_hours <= 4  → decision_score = 85
            Else if latency_hours <= 12 → decision_score = 70
            Else if latency_hours <= 24 → decision_score = 55
            Else if latency_hours <= 72 → decision_score = 35
            Else                          → decision_score = 15

    // 最终分 = 所有决策得分的算术平均
    HumanResponseLatency = round(avg(all decision_score))
```

**特殊说明：**
- 设计决策类门禁（gate-1 规格审批）天然允许更长响应时间，不额外扣分
- 阻塞型门禁（如 gate-7 验收异常）若响应时间 > 72h 会触发 feedbackLoop.stalledSince
- 若 `feedbackLoop.stalledSince` 存在且 decision 涉及同一门禁 → 该决策 score 直接为 0

**可复现性保证：** 时间戳 ISO 8601 求差值，阶梯函数硬编码，纯算术。

---

### 1.5 D5 经验沉淀率 (Experience Capture Rate) — 权重 12%

**度量什么：** 功能完成后的回顾（retro）是否转化为可复用的模式（pattern），以及 ADR 中的决策是否具有可追溯性。

**数据来源：**
- 产物文件 `06-adr.md`、`07-task-retro.md`（文件系统）
- `feature-state.json → gates[6].status`（gate-7 是否通过）
- retro 文件内容的关键段落检测（纯字符串匹配，非 LLM）

**确定性公式：**

```
// 前置条件：feature 必须已到达 S8 或 S9
If currentState not in ["S8", "S9"]:
    ExperienceCaptureRate = null    // 不可评分，权重重新分配
    // 跳过本维度，总分按 88% 缩放（即其余 6 维各 × 1/(1-0.12)）

If currentState in ["S8", "S9"]:
    score = 0

    // --- ADR 部分（最多 40 分）---
    adr_path = featureDir + "/06-adr.md"
    If file_exists(adr_path) AND file_size(adr_path) >= 100:
        score += 20
        // 检测 ADR 关键结构
        content = read(adr_path)
        If content contains "Revisit Trigger" OR "重新审视触发条件" OR "何时重新评估":
            score += 10
        If content contains "## Decision" OR "## 决策" OR "### Decision":
            score += 5
        If content contains "## Consequences" OR "## 后果" OR "### 影响":
            score += 5

    // --- Retro 部分（最多 40 分）---
    retro_path = featureDir + "/07-task-retro.md"
    If file_exists(retro_path) AND file_size(retro_path) >= 100:
        score += 20
        // 检测 Retro 关键结构
        content = read(retro_path)
        If content contains "经验教训" OR "Lessons Learned" OR "## Lesson":
            score += 10
        If content contains "Follow-up" OR "后续行动" OR "## Follow":
            score += 5
        If content contains "Pattern" OR "模式" OR "## Pattern" OR "可复用":
            score += 5

    // --- Pattern 转化检测（20 分）---
    // 检查本功能的经验是否已转化为全局 Pattern
    // 检测 experience/patterns/ 目录下是否存在引用本功能 ID 的 .md 文件
    pattern_dir = workflowDir + "/experience/patterns/"
    If any .md file in pattern_dir contains featureId:
        score += 20

    ExperienceCaptureRate = score
```

**关于 Pattern 转化检测的实现说明：**
- 使用 `grep -l "<featureId>" workflow/experience/patterns/*.md` 进行确定性文件内容搜索
- 不解析语义，仅做字符串包含检查
- 若 patterns 目录不存在或无匹配 → 得 0 分

**可复现性保证：** 文件存在性检查、大小检查、子字符串匹配（大小写敏感），全部是确定性操作。

---

### 1.6 D6 重试成功率 (Retry Success Rate) — 权重 10%

**度量什么：** 门禁失败后经过反馈注入和修正，最终通过的成功率。

**数据来源：**
- `feature-state.json → feedbackLoop` 对象

**确定性公式：**

```
Let FL = feedbackLoop

// 若 feedbackLoop 字段不存在或从未触发过重试
If FL == null OR (FL.retryCount == 0 AND FL.lastFailure == null):
    RetrySuccessRate = 100   // 从未失败 = 满分

// 若有重试历史
If FL.retryHistory exists AND count(FL.retryHistory) > 0:
    Let R = FL.retryHistory                  // 重试记录数组
    Let total = count(R)                     // 总重试次数
    Let passed = count(R where result == "passed")   // 成功次数
    Let failed_again = count(R where result == "failed-again")
    Let escalated = count(R where result == "escalated")

    // 成功率基础分
    success_rate = passed / total
    base = round(success_rate * 80)          // 100% 成功率 → 80 分

    // 反馈注入奖励
    bonus = 0
    If FL.feedbackInjected == true:
        bonus += 10
    If FL.feedbackSource != null AND FL.feedbackSource != "":
        bonus += 5
    If FL.feedbackSummary != null AND FL.feedbackSummary != "":
        bonus += 5

    // 超限惩罚
    penalty = 0
    If total > FL.maxRetries:
        penalty = (total - FL.maxRetries) * 10

    // 停滞检测
    If FL.stalledSince != null:
        stall_hours = (now - FL.stalledSince) in hours
        If stall_hours > 48:
            penalty += 30   // 停滞超过 48h 严重扣分
        Else If stall_hours > 24:
            penalty += 15

    RetrySuccessRate = max(0, min(100, base + bonus - penalty))

// 若有 lastFailure 但 retryHistory 为空（失败后一次重试都没有）
If FL.lastFailure != null AND (FL.retryHistory == null OR count(FL.retryHistory) == 0):
    // 检查是否停滞
    If FL.stalledSince != null:
        stall_hours = (now - FL.stalledSince) in hours
        If stall_hours > 48:
            RetrySuccessRate = 0
        Else:
            RetrySuccessRate = 30
    Else:
        // 刚失败，还未到重试阶段
        RetrySuccessRate = 50
```

**说明：**
- 从未失败 → 满分（不惩罚无过错者）
- 失败 1 次后成功（feedback 注入有效）→ base 80 + bonus 10~20 = 90~100
- 失败 3 次仍未通过 → base 0 + bonus 若有 ≈ 10-20，penalty 若超 maxRetries ≈ 0-10，约 10-20 分
- 停滞超过 48h → 最多 0 分

**可复现性保证：** retryCount 是整数，result 是枚举值，字段存在性检查和布尔值精确匹配，纯算术。

---

### 1.7 D7 文档健康度 (Document Health) — 权重 9%

**度量什么：** ADR 和 Retro 是否真实存在于文件系统，且内容达到最低质量门槛。

**数据来源：**
- 产物文件 `06-adr.md`、`07-task-retro.md`（文件系统检查）
- `feature-state.json → gates[6].status`（gate-7 整体状态）

**确定性公式：**

```
// 前置条件
If currentState not in ["S8", "S9"]:
    DocumentHealth = null      // 不可评分，权重重新分配
    // 跳过本维度，总分按 91% 缩放（即其余维度各 × 1/(1-0.09)）

If currentState in ["S8", "S9"]:
    adr_score = 0
    retro_score = 0

    // --- ADR 评分（0-50）---
    adr_path = featureDir + "/06-adr.md"
    If file_exists(adr_path):
        size = file_size(adr_path)
        If size >= 500:
            adr_score = 50
        Else If size >= 300:
            adr_score = 40
        Else If size >= 100:
            adr_score = 25
        Else:
            adr_score = 10
    // ADR 不存在 → adr_score = 0

    // --- Retro 评分（0-50）---
    retro_path = featureDir + "/07-task-retro.md"
    If file_exists(retro_path):
        size = file_size(retro_path)
        If size >= 500:
            retro_score = 50
        Else If size >= 300:
            retro_score = 40
        Else If size >= 100:
            retro_score = 25
        Else:
            retro_score = 10
    // Retro 不存在 → retro_score = 0

    DocumentHealth = adr_score + retro_score
```

**说明：**
- 此维度与 D5（经验沉淀率）互补但不重复：D5 关注「内容是否转化为可复用模式」，D7 关注「文档是否存在且体量达标」
- 500 bytes 是一个包含基本结构和具体内容的合理阈值
- 仅靠文件大小判定，不做内容语义分析

**可复现性保证：** `test -f` 检查存在性，`wc -c` 读取字节数，纯文件系统操作。

---

## 2. 加权总分

### 2.1 正常加权公式

```
TotalScore = round(
    D1_ProcessIntegrity        * 0.22
  + D2_ReviewQuality           * 0.22
  + D3_DegradationFrequency    * 0.15
  + D4_HumanResponseLatency    * 0.10
  + D5_ExperienceCaptureRate   * 0.12
  + D6_RetrySuccessRate        * 0.10
  + D7_DocumentHealth          * 0.09
)
```

结果：0-100 的整数。

### 2.2 存在 null 维度时的权重重新分配

若某维度因「功能未推进到对应阶段」返回 `null`（不可评分），其权重按比例分配给其余有效维度：

```
Let valid_dims = { dim in [D1..D7] where dim != null }
Let valid_weight_sum = sum(weight of dim in valid_dims)
Let scaling_factor = 1.0 / valid_weight_sum

For each dim in valid_dims:
    adjusted_weight = weight(dim) * scaling_factor

TotalScore = round(sum over valid_dims: score(dim) * adjusted_weight)
```

**示例：**
- 功能在 S5（尚未到 S8），D5 和 D7 返回 null
- 有效维度 D1-D4, D6，原始权重和 = 0.22 + 0.22 + 0.15 + 0.10 + 0.10 = 0.79
- 缩放因子 = 1 / 0.79 ≈ 1.2658
- D1 调整后权重 = 0.22 × 1.2658 ≈ 0.2785

### 2.3 评分等级

| 分数区间 | 等级 | 颜色标识 |
|----------|------|----------|
| 85-100 | A — 优秀 | 绿色 |
| 70-84 | B — 良好 | 蓝绿色 |
| 55-69 | C — 及格 | 黄色 |
| 40-54 | D — 需改进 | 橙色 |
| 0-39 | F — 不及格 | 红色 |

---

## 3. 评分脚本接口定义

### 3.1 接口概览

评分脚本 `workflow/eval/score.py` 提供两个主要模式：

```
# 单功能评分
score.py --feature <feature-id> [--baseline <baselines.json>] [--output <score.json>]

# 全项目评分（遍历所有功能文件夹）
score.py --all [--baseline <baselines.json>] [--output-dir <dir>]
```

### 3.2 输入接口

**输入 1：feature-state.json（必需）**

```
路径：workflow/features/<featureId>/feature-state.json
格式：严格符合 workflow/feature-state.schema.json
编码：UTF-8
```

脚本验证：
1. JSON 可解析（`json.load()` 无异常）→ 否则所有维度 null，输出 warning
2. `featureId` 字段存在且匹配文件夹名 → 否则 warning
3. `gates` 数组长度 == 7 → 否则 warning（但仍尝试评分）
4. 每个 gate 的 `status` 取值为 schema 定义的 4 个枚举值之一

**输入 2：baselines.json（可选）**

```
路径：workflow/eval/baselines.json
格式：见第 4 节基线管理
若未提供 → 仅输出绝对分数，不输出 baselineComparison
```

**输入 3：功能文件夹（隐式）**

```
路径：workflow/features/<featureId>/
用途：检查产物文件的存在性和大小
```

### 3.3 输出接口

**输出：score.json**

写入路径：`workflow/features/<featureId>/score.json`（与 feature-state.json 同目录）

```json
{
  "engine": "scoring-engine-v1",
  "scoredAt": "2026-06-16T12:00:00Z",
  "scoredBy": "script:score.py",
  "featureId": "ai-werewolf",
  "llmCalls": 0,
  "deterministicHash": "a1b2c3d4e5f6",
  "scores": {
    "total": 78,
    "grade": "B",
    "dimensions": {
      "processIntegrity": {
        "score": 100,
        "weight": 0.22,
        "weighted": 22.0,
        "status": "scored"
      },
      "reviewQuality": {
        "score": 70,
        "weight": 0.22,
        "weighted": 15.4,
        "status": "scored"
      },
      "degradationFrequency": {
        "score": 90,
        "weight": 0.15,
        "weighted": 13.5,
        "status": "scored"
      },
      "humanResponseLatency": {
        "score": 60,
        "weight": 0.10,
        "weighted": 6.0,
        "status": "scored"
      },
      "experienceCaptureRate": {
        "score": 55,
        "weight": 0.12,
        "weighted": 6.6,
        "status": "scored"
      },
      "retrySuccessRate": {
        "score": 100,
        "weight": 0.10,
        "weighted": 10.0,
        "status": "scored"
      },
      "documentHealth": {
        "score": 50,
        "weight": 0.09,
        "weighted": 4.5,
        "status": "scored"
      }
    }
  },
  "baselineComparison": {
    "baselineVersion": "1.0.0",
    "baselineTotal": 72,
    "delta": 6,
    "status": "above_baseline",
    "dimensionDeltas": {
      "processIntegrity": 15,
      "reviewQuality": 5,
      "degradationFrequency": 10,
      "humanResponseLatency": -5,
      "experienceCaptureRate": -10,
      "retrySuccessRate": 25,
      "documentHealth": -5
    }
  },
  "warnings": [
    {
      "dimension": "experienceCaptureRate",
      "code": "NO_PATTERN_FOUND",
      "message": "未在 experience/patterns/ 目录找到引用本功能的 Pattern 文件",
      "severity": "P3"
    }
  ],
  "rawInputs": {
    "featureId": "ai-werewolf",
    "currentState": "S9",
    "mode": "dual-agent",
    "gatesPassed": 7,
    "gatesSkipped": 0,
    "gatesApplicable": 7,
    "artifactsPresent": 8,
    "artifactsExpected": 8,
    "reviewFindingsGrillMe": 3,
    "reviewFindingsCodeReview": 2,
    "reviewP0Count": 1,
    "reviewP1Count": 2,
    "fallbackEventCount": 1,
    "fallbackSeverityWeight": 2,
    "singleAgentSwitchCount": 0,
    "humanDecisionCount": 3,
    "humanDecisionAvgLatencyHours": 5.2,
    "retroExists": true,
    "retroSizeBytes": 450,
    "adrExists": true,
    "adrSizeBytes": 380,
    "patternReferencesFound": 0,
    "retryTotal": 1,
    "retrySuccess": 1,
    "feedbackInjected": true,
    "stalledHours": null
  }
}
```

### 3.4 字段说明

| 字段路径 | 类型 | 说明 |
|----------|------|------|
| `engine` | string | 评分引擎版本标识，固定为 `"scoring-engine-v1"` |
| `scoredAt` | ISO 8601 | 评分执行时间 |
| `scoredBy` | string | 评分执行者标识 |
| `featureId` | string | 功能标识符 |
| `llmCalls` | integer | LLM 调用次数，必须为 0 |
| `deterministicHash` | string | SHA256 前 12 位 hex |
| `scores.total` | integer | 0-100 总分 |
| `scores.grade` | string | A/B/C/D/F 等级 |
| `scores.dimensions.<dim>.score` | integer\|null | 维度分数，null 表示不可评分 |
| `scores.dimensions.<dim>.weight` | float | 维度原始权重 |
| `scores.dimensions.<dim>.weighted` | float | 实际加权贡献（已考虑重分配） |
| `scores.dimensions.<dim>.status` | string | `"scored"` / `"null_not_applicable"` / `"null_missing_data"` |
| `baselineComparison.status` | string | `"above_baseline"` / `"at_baseline"` / `"below_baseline"` / `"no_baseline"` |
| `baselineComparison.delta` | integer | 总分与基线的差值 |
| `warnings[].code` | string | 警告代码，便于自动化处理 |
| `rawInputs` | object | 所有用于计算的原始输入值，便于手工验算 |

---

## 4. 基线管理规则

### 4.1 基线定义

基线是项目级别的参考分数，存储在 `workflow/eval/baselines.json`，用于判断当前功能的工作流健康度是否「相对于项目正常水平」合理。

```json
{
  "version": "1.0.0",
  "updatedAt": "2026-06-16T12:00:00Z",
  "currentBaseline": {
    "totalScore": 72,
    "dimensions": {
      "processIntegrity": 85,
      "reviewQuality": 65,
      "degradationFrequency": 80,
      "humanResponseLatency": 60,
      "experienceCaptureRate": 55,
      "retrySuccessRate": 90,
      "documentHealth": 70
    },
    "activatedAt": "2026-06-01T00:00:00Z",
    "basedOnFeatureCount": 5,
    "basedOnFeatures": ["feature-a", "feature-b", "feature-c", "feature-d", "feature-e"],
    "activatedBy": "human:oldmanpushbike"
  },
  "candidate": null,
  "history": [
    {
      "baselineId": "bl-001",
      "totalScore": 68,
      "dimensions": {},
      "activatedAt": "2026-05-01T00:00:00Z",
      "basedOnFeatures": ["feature-x", "feature-y", "feature-z"],
      "activatedBy": "human:oldmanpushbike"
    }
  ]
}
```

### 4.2 基线计算规则

基线由所有已归档（S9）且已完成评分的功能的各维度分数取**中位数**（而非均值，抗异常值干扰）生成：

```
For each dimension d in [D1..D7]:
    baseline_dim[d] = median(score[d] for all S9 features with completed scoring)

baseline_total = round(sum(baseline_dim[d] * weight[d] for d in [D1..D7]))
```

### 4.3 新基线激活条件

**候选基线自动生成条件（三条同时满足）：**
1. 至少 3 个已归档（S9）功能完成了评分
2. 这 3 个功能的平均总分超过当前基线 5 分以上 **或** 低于当前基线 5 分以上（即发生了显著偏离）
3. 无任何维度的中位数低于当前基线对应维度 15 分以上

**激活流程（不可自动化）：**

```
评分脚本运行 → 检查激活条件 → 若满足 → 写入 baselines.json 的 candidate 字段
    → 向人类发出通知：「候选基线已生成，总分 XX，请审查」
    → 人类审查 candidate → 批准或拒绝
        → 批准：candidate 移至 currentBaseline，旧基线移至 history
        → 拒绝：candidate 清空，记录拒绝理由在 history 中
```

**铁律：基线变更必须人类手动确认。** 基线提高意味着所有现有功能「相对变差」，这是一个有后果的决策。不可由脚本自动切换。

### 4.4 基线对比输出

每个功能的 `score.json → baselineComparison` 字段包含与当前基线的对比：

- `delta` = 功能总分 - 基线总分（正数 = 优于基线）
- `dimensionDeltas` = 逐维度差值
- `status` 判定：
  - `above_baseline`：总分 >= 基线 + 5
  - `at_baseline`：|总分 - 基线| < 5
  - `below_baseline`：总分 <= 基线 - 5
  - `no_baseline`：基线文件不存在或无可用的 currentBaseline

### 4.5 基线下游联动

| 消费者 | 触发条件 | 行为 |
|--------|----------|------|
| dashboard.html | 每次加载 | 对比每个功能与基线的差异，红/黄/绿着色 |
| gate-check.sh --strict | 评分低于基线 30 分以上 | 输出额外警告，建议人类介入 |
| 经验管道 (pipeline.md) | 某维度连续 3 个功能低于基线 | 在 patterns/ 目录生成候选 Pattern 文件 |
| CI 质量门禁 | 功能评分低于基线 15 分 | 允许合入但标记 `quality-watch` 标签 |

---

## 5. 确定性 Hash

每次评分的 `deterministicHash` 确保同一份 feature-state.json 在任意时间跑分得到相同的 hash：

```
hash_input = featureId + "|" +
    D1 + "|" + D2 + "|" + D3 + "|" + D4 + "|" + D5 + "|" + D6 + "|" + D7

deterministicHash = SHA256(hash_input)[:12]
```

**注意：**
- Hash 计算使用各维度原始分数（含 null），不含权重调整、不含与基线的对比
- 目的：让任何人都能验算——拿到 feature-state.json，跑分，对比 hash，验证分数未被篡改或漂移

---

## 6. 边界情况处理

| 情况 | D1 | D2 | D3 | D4 | D5 | D6 | D7 | 总分 |
|------|----|----|----|----|----|----|----|------|
| S0，无任何产物 | 按比例 | null | 评分 | 50 | null | 100 | null | 仅有效维度加权 |
| feature-state.json 不存在 | null | null | null | null | null | null | null | null + warning |
| feature-state.json JSON 解析失败 | null | null | null | null | null | null | null | null + warning |
| gates[] 长度 != 7 | 按实际长度 | 评分 | 评分 | 评分 | 评分 | 评分 | 评分 | 正常 + warning |
| gates[].status 非标准枚举值 | 视为 failed | 评分 | 评分 | 评分 | 评分 | 评分 | 评分 | 正常 + warning |
| fallbackEvents 为 null（未填写） | — | — | 100 | — | — | — | — | 假设无误 + warning |
| fallbackEvents 为空数组 [] | — | — | 100 | — | — | — | — | 明确无误 |
| humanDecisions 为空数组 | — | — | — | 50 | — | — | — | 中性分 |
| feedbackLoop 不存在 | — | — | — | — | — | 100 | — | 假设无失败 |
| stateHistory 为空 | 评分 | 评分 | 评分 | 评分 | 评分 | 评分 | 评分 | warning |
| currentState 枚举值异常 | 均返回 null | null | null | null | null | null | null | null + warning |
| degree 处在 S8/S9 但产物文件缺失 | 评分 | — | — | — | 0 | — | 0 | 正常，但 D5/D7 为 0 |

---

## 7. 与 gate-check.sh 的关系

```
gate-check.sh              scoring-engine（本文档）
─────────────              ──────────────────────
检查门禁是否通过             评估通过的质量如何
二进制 pass/fail             0-100 连续分数
实时运行（手动 / CI）         归档时运行 + 定期巡检
面向 Agent                   面向人类 + 经验管道
输出 stdout                  输出 score.json 文件
校验 feature-state.json     消费 feature-state.json
拦截功能推进                  不影响功能推进，仅做质量评估
```

**互补关系，互不替代：**
- `gate-check.sh` 回答「门禁过了没有？」——阻止未通过门禁的代码进入下一阶段
- `scoring-engine` 回答「过得怎么样？」——告诉人类工作流在变好还是变差
- 一个功能可以全部门禁通过（gate-check.sh 全绿），但评分只有 45 分（流程走了，但走得敷衍）

---

## 8. 确定性保证

### 8.1 保证项

| 保证项 | 实现方式 |
|--------|----------|
| 零 LLM 调用 | 评分脚本不导入任何 LLM SDK，不发起网络请求 |
| 纯算术 | 所有公式仅使用 + - * / min max round count |
| 枚举匹配 | 所有字符串比较使用精确匹配（==），不使用模糊匹配或语义理解 |
| 文件操作 | 仅使用 `os.path.exists` + `os.path.getsize` + `glob`，均为 POSIX 确定操作 |
| 时间戳差值 | ISO 8601 解析 → epoch seconds → 差值，纯算术 |
| Hash 校验 | SHA256(分数拼接) 确保不可篡改 |

### 8.2 不保证项

| 不保证项 | 原因 | 缓解措施 |
|----------|------|----------|
| 跨时区的时间戳一致性 | 依赖 feature-state.json 中的 ISO 8601 精度 | 要求所有时间戳使用 UTC（Z 后缀） |
| 产物文件内容质量 | 仅检查大小，不评估内容 | D5/D7 的字符串匹配是对内容质量的弱信号 |
| 降级事件的完整性 | 依赖 Agent 或人类诚实记录 fallbackEvents | gate-check.sh 可交叉校验 mode 字段与 fallbackEvents 的一致性 |

---

## 9. 实现清单

本文档定义的评分引擎是纯算法规范，不绑定特定语言。已知实现（或计划实现）：

| 实现 | 位置 | 用途 |
|------|------|------|
| Python 脚本 | `workflow/eval/score.py`（待实现） | CLI 单功能 / 全项目评分，输出 score.json |
| gate-check.sh 内嵌 | `workflow/scripts/gate-check.sh --score` 模式（待实现） | 与门禁检查联动，一站式输出 |
| 浏览器端 JS | `workflow/eval/dashboard.html` 内嵌引擎（待实现） | 实时渲染评分仪表盘，无需后端 |

无论何种实现，核心约束不变：**零 LLM 调用，纯算术，3 次跑分 hash 一致。**

---

## 附录 A：权重分配决策记录

| 维度 | 权重 | 设计理由 |
|------|------|----------|
| D1 流程完整性 | 22% | 流程是工作流的基础——产物缺失意味着门禁形同虚设 |
| D2 审查质量 | 22% | 审查是发现问题的最后屏障——与流程同权重 |
| D3 降级频率 | 15% | 降级不可避免，但频繁降级说明架构有问题 |
| D4 人工响应延迟 | 10% | 人类速度不是追求目标，但极端延迟说明流程卡死 |
| D5 经验沉淀率 | 12% | 知识捕获是长期价值，权重略高于文档健康度 |
| D6 重试成功率 | 10% | 衡量反馈回路的有效性 |
| D7 文档健康度 | 9% | 文档是知识载体，但权重略低以避免「写文档刷分」 |

权重设计遵循：**结构 > 审查 > 韧性 > 知识 > 速度**。

---

## 附录 B：评分脚本伪代码

```python
#!/usr/bin/env python3
"""
workflow/eval/score.py — 确定性评分引擎
用法：python score.py --feature <feature-id>
       python score.py --all
约束：零 LLM 调用，零网络请求，纯算术 + 文件系统操作
"""

import json, os, sys, hashlib
from datetime import datetime, timezone
from pathlib import Path

def score_feature(feature_dir: Path, baseline: dict | None) -> dict:
    """对单个功能进行评分，返回 score.json 对象"""

    # 1. 加载 feature-state.json
    state_path = feature_dir / "feature-state.json"
    if not state_path.exists():
        return _null_score(feature_dir.name, "feature-state.json 不存在")

    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return _null_score(feature_dir.name, "feature-state.json 解析失败")

    feature_id = state.get("featureId", feature_dir.name)

    # 2. 逐维度计算
    raw = {}

    # D1 流程完整性
    raw["processIntegrity"] = _score_process_integrity(state, feature_dir)

    # D2 审查质量
    raw["reviewQuality"] = _score_review_quality(state)

    # D3 降级频率
    raw["degradationFrequency"] = _score_degradation_frequency(state)

    # D4 人工响应延迟
    raw["humanResponseLatency"] = _score_human_latency(state)

    # D5 经验沉淀率
    raw["experienceCaptureRate"] = _score_experience_capture(state, feature_dir)

    # D6 重试成功率
    raw["retrySuccessRate"] = _score_retry_success(state)

    # D7 文档健康度
    raw["documentHealth"] = _score_document_health(state, feature_dir)

    # 3. 权重分配
    weights = {
        "processIntegrity": 0.22,
        "reviewQuality": 0.22,
        "degradationFrequency": 0.15,
        "humanResponseLatency": 0.10,
        "experienceCaptureRate": 0.12,
        "retrySuccessRate": 0.10,
        "documentHealth": 0.09,
    }
    total, dimensions = _weighted_total(raw, weights)

    # 4. 确定性 Hash
    hash_input = f"{feature_id}|" + "|".join(
        str(raw.get(d, "null")) for d in weights
    )
    det_hash = hashlib.sha256(hash_input.encode()).hexdigest()[:12]

    # 5. 基线对比
    baseline_comparison = _compare_baseline(total, raw, baseline)

    # 6. 构建输出
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
        "warnings": _collect_warnings(state, raw),
        "rawInputs": _collect_raw_inputs(state, raw, feature_dir),
    }


# 各维度评分函数（返回 int 或 None）
# _score_process_integrity, _score_review_quality, ...
# 详细实现见各维度公式
```

---

## 附录 C：修订历史

| 版本 | 日期 | 变更 |
|------|------|------|
| 1.0 | 2026-06-16 | 初始版本：七维评分体系、确定性公式、基线管理、score.json 接口定义 |
