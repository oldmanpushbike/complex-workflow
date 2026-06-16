# 经验三级进化管道 (Experience Evolution Pipeline)

> **核心原则：经验不沉淀，项目永远在重复犯错。**
>
> 三级进化：Lesson → Pattern → Instinct。每级晋升需人工确认。
> 评测平台只评估不执行——管道提供经验，不替 AI 做决策。

---

## 1. 架构总览

```
┌──────────────────────────────────────────────────────────┐
│                    经验三级进化管道                         │
│                                                          │
│  Level 1: Lesson（教训）                                   │
│  ┌────────────┐    提取自 07-task-retro.md                │
│  │ 单功能/单任务 │ ──→ 存储在 lessons/<feature-id>/        │
│  │ 具体、上下文绑定│    自动提取，无需确认                    │
│  └──────┬─────┘                                          │
│         │ 跨功能归纳（人工确认）                              │
│         ▼                                                │
│  Level 2: Pattern（模式）                                  │
│  ┌────────────┐    由 ≥2 个相关 Lesson 归纳               │
│  │ 跨项目/跨功能 │ ──→ 存储在 patterns/<pattern-name>.md   │
│  │ 抽象、可迁移  │    人工确认后晋升                        │
│  └──────┬─────┘                                          │
│         │ 规则化注入（人工确认 + 签核）                        │
│         ▼                                                │
│  Level 3: Instinct（本能规则）                              │
│  ┌────────────┐    由 Pattern 转化为可执行规则              │
│  │ 系统自动执行  │ ──→ 注入 AGENTS.md / CLAUDE.md /         │
│  │ 不再需要人类记住│    CODEX.md / state-machine.md         │
│  └────────────┘    人工确认后写入系统文件                    │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 1.1 三级对比

| 维度 | Lesson (L1) | Pattern (L2) | Instinct (L3) |
|------|-------------|-------------|---------------|
| 范围 | 单功能/单任务 | 跨功能/跨项目 | 全系统 |
| 抽象层级 | 具体、上下文绑定 | 抽象、可迁移 | 规则化、可机械执行 |
| 确认要求 | 无需确认（自动提取） | 人工确认 | 人工确认 + 签核 |
| 存储位置 | `lessons/<feature-id>/` | `patterns/<name>.md` | 注入系统文件 |
| 触发条件 | 每次 retro 完成 | ≥2 个相关 Lesson | Pattern 有效 ≥3 次 + 确定性可检查 |
| 可被 AI 修改 | 是（仅 draft） | 否（必须人工） | 否（必须人类执行写入） |

---

## 2. Level 1: Lesson（教训）

### 2.1 定义

Lesson 是经验管道的最小单元。它记录单次功能开发中"哪里出错了、为什么、学到了什么"。Lesson 是经验管道的原料——没有高质量的 Lesson，就不可能有 Pattern 和 Instinct。

### 2.2 来源

- 每个功能的 `07-task-retro.md` 在 S8 完成后自动提取
- 从 retro 的以下字段中提取：
  - **"What Failed Or Slowed Us Down"** → Lesson 的核心事件
  - **"Tool / Agent Notes"** → Lesson 的根因线索
  - **"Reusable Pattern Found"** → Lesson 的改进建议
  - **"Knowledge To Carry Forward"** → Lesson 的总结陈述

### 2.3 触发条件

| 触发事件 | 时机 | 执行者 |
|---------|------|--------|
| 功能进入 S8 且 `07-task-retro.md` 写入完成 | 每次 retro 后立即 | `extract-lessons.sh`（零 LLM） |
| 人类手动创建 Lesson | 任何时候 | 人类 |
| Code Review 中发现严重问题（P0/P1）且 retro 尚未覆盖 | S6 后 | 审查 Agent 建议，人类确认 |

### 2.4 存储位置

```
workflow/experience/lessons/<feature-id>/lesson-<序号>.md
```

其中 `<序号>` 为三位数字（如 `001`, `002`），表示该功能下的 Lesson 顺序。

### 2.5 文件格式模板

```markdown
---
# ── Lesson 元数据（由 extract-lessons.sh 自动填写草稿）──
lessonId: LSN-<feature-id>-<序号>
featureId: <feature-id>
taskId: <task-id 或 "feature-level">
source: 07-task-retro.md
extractedAt: <ISO 8601 时间戳>
status: draft | reviewed | promoted
severity: P0 | P1 | P2 | P3
reviewedBy: null
reviewedAt: null
tags: [tag1, tag2, tag3]
relatedGates: [gate-1, gate-2]
relatedPatterns: []
promotedToPattern: null
---

# <一句摘要>

## 发生了什么

> 具体的事件描述。包含足够的上下文，使 6 个月后的人能理解。
> 回答：谁（Agent/人类）、什么时候（哪个状态/门禁）、怎么发现的。

## 为什么会发生

> 根因分析。是流程问题？工具问题？知识缺口？假设错误？
> 使用"5 Whys"方法至少追问 1 层。

## 影响

> 对功能进度、质量、人类介入次数的影响。
> 尽量量化：延误了多久？增加了几次返工？多了几次人工介入？

## 学到了什么

> 一句话可执行的经验。用粗体。

**教训：** <一句话，可独立理解>

## 应该改变什么

> 具体建议：修改哪个文件、增加哪个检查、改变哪个流程。
> 每个建议必须是可验证的（完成后可以打勾）。

- [ ] <可操作的建议 1 — 附目标文件/系统>
- [ ] <可操作的建议 2 — 附目标文件/系统>

## 关联 Pattern 候选

> 此 Lesson 可能与哪些已有 Pattern 相关？或建议创建什么新 Pattern？

- 关联已有 Pattern: <pattern-name> 或 "无"
- 建议新 Pattern: <提议的模式名> 或 "无"
- 建议理由: <一句话>
```

### 2.6 自动提取规则（零 LLM 调用）

从 `07-task-retro.md` 中提取 Lesson 的确定性规则：

| retro 字段 | 提取方式 | Lesson 字段 |
|-----------|---------|------------|
| "What Failed Or Slowed Us Down" | 每个非空列表项 → 一个 Lesson 草稿 | `## 发生了什么` |
| "Tool / Agent Notes" | 标注了问题的条目（关键词：失败/不可用/降级/超时） → 补充到已有 Lesson | `## 为什么会发生` |
| "Reusable Pattern Found" | 若回答了 "Should this become..." → 生成 Lesson 草稿 | `## 应该改变什么` |
| "Knowledge To Carry Forward" | 直接复制为 Lesson 总结 | `## 学到了什么` |

**自动提取脚本**（`workflow/experience/extract-lessons.sh`）仅做：
1. 扫描 `workflow/features/*/07-task-retro.md`
2. 检查 retro 中非空字段
3. 若尚未提取为 Lesson（`lessons/<feature-id>/` 不存在或内容较旧），生成 Lesson 文件草稿
4. 标记 `status: draft`，等待人类审阅
5. 自动生成或更新 `lessons/_index.md`

**重要：** 提取是自动的，但 Lesson 的 `severity` 和 `tags` 由人类在审阅时填写。自动提取时 severity 默认为 `P3`（待人类确认）。

### 2.7 Lesson 生命周期

```
draft ──→ reviewed ──→ promoted
  │          │            │
  │          │            └──→ 已晋升为 Pattern 的 Lesson
  │          │                 不移除，标记 status: promoted
  │          │                 + 填写 promotedToPattern
  │          │
  │          └──→ 人类审阅过，修正了 severity/tags
  │               status: reviewed
  │
  └──→ 自动提取的初始状态
       severity 默认为 P3
```

**归档规则：**
- `draft` 状态超过 60 天未审阅 → 标记为 `stale`，生成提醒
- `stale` 状态超过 90 天 → 自动标记为 `archived`，移出活跃索引
- `reviewed` 或 `promoted` 的 Lesson 永不自动归档

---

## 3. Level 2: Pattern（模式）

### 3.1 定义

Pattern 是从多个 Lesson 中归纳出的跨功能、可迁移的抽象模式。它回答"这一类问题反复出现的原因是什么、如何系统性地解决"。

### 3.2 来源

- 由 ≥2 个相关 Lesson 归纳（主要路径）
- 由跨功能评分趋势触发（某维度连续 3 个功能低于基线）
- 由人类在 Code Review 或项目回顾中直接识别

### 3.3 晋升硬性条件（必须全部满足）

| # | 条件 | 验证方式 |
|---|------|---------|
| 1 | ≥2 个**不同功能**的 Lesson 指向同一类问题 | 检查 `sourceLessons` 的 `featureId` 去重 ≥2 |
| 2 | 至少 1 个源 Lesson 的 severity 为 P0 或 P1 | 检查源 Lesson 的 `severity` 字段 |
| 3 | 问题不是某个功能特有的上下文导致的 | 人工判断：问题描述是否包含"功能X特有"的限定词 |

### 3.4 晋升软性条件（满足越多越好，非必须）

- 至少 1 个源 Lesson 提出了具体的文件修改建议
- 问题在评分引擎的某个维度中体现为持续低分（连续 ≥3 个功能 < 基线）
- 多个编排者（Codex + Claude）都遇到了同类问题
- 问题的解决方案不依赖特定技术栈

### 3.5 人工确认流程（学习型 Checkpoint 格式）

Pattern 的晋升必须经过人工确认。以下为 Agent 向人类提案时的标准输出格式。

---

<div class="checkpoint-card" style="border: 2px solid #d4a574; border-radius: 12px; padding: 20px; margin: 16px 0;">

### 学习型 Checkpoint: Pattern 晋升审批

<h4>📋 背景 (Context)</h4>

此时发生了什么：
- 经验管道自动检测到 ≥2 个 Lesson 指向同一类问题，或评分引擎触发了 Pattern 提案
- 已生成 `patterns/<pattern-name>.md` 草稿（status: `proposed`）
- 源 Lessons 列表已填入文件头，证据表已填写
- 此 Pattern 如果被接受，将影响所有后续功能的决策依据

关联的前序决策：
- 源 Lessons 在各自的 retro 中被标记为需要关注（P0/P1）
- 评分引擎的相关维度可能连续低于基线

不做出决策的后果：
- 同类问题将在后续功能中继续出现
- 每周 1 个出现 → 每季度约 12 次同类返工
- Pattern 草稿将过期（60 天后标记为 stale）

<h4>🔍 分析 (Analysis)</h4>

Agent 已考虑的因素：
- 源 Lessons 的真实性和准确性（已逐条对照 retro 原文验证）
- 问题的跨功能特征：是否真的"跨功能"还是同一功能的多个视角
- 替代方案：是否可以通过修改单个模板/流程解决，而无需建立新 Pattern
- 已有 Patterns 中是否已存在类似的（通过 tags 交叉匹配）

已排除的方案及理由：
- 创建项目级一次性修复（而非 Pattern）：问题已在 ≥2 个功能中出现，点状修复不防复发
- 等待更多证据：当前证据已满足晋升硬性条件，延迟不会带来更多信息

<h4>📚 经验课堂 (Learning)</h4>

> **有经验的工程管理者会怎么想？**
>
> Pattern 的本质是"组织学习"的制度化。Google 的 Site Reliability Engineering 强调"事后剖析（postmortem）不是终点，blameless culture 是起点"。将 blameless 的事后剖析沉淀为可操作的行动项（action items），才是事后剖析的价值闭环。
>
> 关键原则：
> - **Pattern 不是责备清单，是预防清单。** 如果 Pattern 读起来像"X Agent 又犯错了"，那它的抽象层级不够——Pattern 应该描述系统缺陷，而非人的缺陷。
> - **过度模式化是陷阱。** 如果一个问题只在 2 个功能中出现、且后续不太可能复现，创建一个 Pattern 是噪音而非信号。
> - **Pattern 需要"金发姑娘原则"：** 太具体则无迁移价值（不如留在 Lesson），太抽象则无操作意义（不如不写）。

<h4>🎯 选项 (Options)</h4>

| | 方案 A: 接受并激活 | 方案 B: 要求修改 | 方案 C: 拒绝，保留为 Lesson |
|---|---|---|---|
| 简述 | Pattern 状态变为 `active`，源 Lessons 标记 `promoted` | Pattern 返回 `draft` 状态，Agent 根据反馈修改 | Pattern 文件删除或标记 `rejected`，源 Lessons 保持 `reviewed` |
| ✅ 优势 | 所有后续功能自动受益，经验正式进入系统 | 确保 Pattern 的措辞和范围精确 | 不引入未经充分验证的模式 |
| ⚠️ 风险 | 若 Pattern 有误，可能误导后续功能 | 循环修改可能延迟沉淀 | 同类问题将继续出现 |
| 💰 成本 | 低（一次性批准） | 中（需要多轮沟通） | 高（每次功能复发同类问题的累积成本） |
| 适合谁 | Pattern 措辞清晰、证据充分 | 对 Pattern 的范围/措辞有疑虑 | Pattern 的跨功能证据不足 |

<h4>⭐ 推荐 (Recommendation)</h4>

<div style="background:#1a2e1a; border:1px solid #27ae60; border-radius:8px; padding:12px; margin:8px 0;">

**推荐方案：** 基于证据质量决定。

- 若 Pattern 的证据表 ≥3 个 Lesson 且来源 ≥3 个功能 → 推荐 **方案 A**
- 若 Pattern 的证据表刚好 2 个 Lesson 且 severity 均 ≤ P1 → 推荐 **方案 B**（补充更多证据再激活）
- 若 2 个源 Lesson 来自同一个功能的不同任务 → 推荐 **方案 C**（不满足跨功能条件）

**推理链路：** Pattern 的数量应保持精简——每个激活的 Pattern 都会增加 Agent 的认知负荷。优先确保每个激活的 Pattern 都是"真阳性"。

**何时应推翻此推荐：** 若问题正在当前活跃功能中复发，即使证据不足也可提前激活（加注 `early-activation` 标签）。

</div>

<h4>✋ 你的决策 (Decision)</h4>

请选择：`[ ] 方案 A / [ ] 方案 B / [ ] 方案 C`

若选方案 B，请说明需要修改的具体内容：`______`

</div>

---

### 3.6 文件格式模板

存储路径：`workflow/experience/patterns/<pattern-name>.md`

```markdown
---
patternId: PTN-<序号>
patternName: <kebab-case 名称>
status: proposed | review | accepted | rejected | active | dormant | superseded
proposedAt: <ISO 8601 时间戳>
acceptedAt: null
proposedBy: claude | codex | human
confirmedBy: null
sourceLessons: [LSN-feature-a-001, LSN-feature-b-002]
sourceScores: [{dimension: "reviewDepth", trend: "declining", consecutiveBelowBaseline: 3}]
tags: [tag1, tag2]
supersedes: null
supersededBy: null
instinctCandidate: false
instinctName: null
recurrenceCount: 0
lastTriggeredFeature: null
lastTriggeredAt: null
---

# <模式标题>

## 症状

> 可观察的现象。当这些现象出现时，可能就是此模式在起作用。
> 每个症状应足够具体，使 Agent 可以在工作中自行识别。

- 现象 1
- 现象 2
- 现象 3

## 根因

> 为什么这个模式会反复出现？是流程缺陷？工具局限？认知偏差？还是模板缺失？

## 触发条件

> 什么情况下这个模式最可能激活？
> 回答：功能特征、Agent 角色、技术栈、时间压力等维度。

- 条件 1（如：功能涉及多 Agent 协作时）
- 条件 2（如：功能增删了 API 契约时）
- 条件 3

## 解决方案

> 已经验证有效的对策。分三层。

1. **主动措施（预防）：** <在问题发生前做什么 — 修改模板、增加门禁检查、预声明风险>
2. **反应措施（检测）：** <如何及早发现问题 — 自动检查、审查清单项、状态转移条件>
3. **补救措施（修复）：** <问题发生后如何修复 — 最小步骤、责任方、回滚方式>

## 关联证据

| Lesson ID | 功能 | 任务 | 严重度 | 摘要 |
|-----------|------|------|--------|------|
| LSN-xxx-001 | feature-a | task-1 | P0 | ... |
| LSN-xxx-002 | feature-b | task-3 | P1 | ... |

## Instinct 候选

> 此 Pattern 是否应该转化为 Instinct（自动注入系统的规则）？

- [ ] 是，建议 Instinct: `<instinct-name>`
  - 确定性检查方式：`<描述如何在不依赖上下文判断的情况下自动检查>`
- [ ] 否，原因: `<原因 — 如：需要人类判断、依赖外部系统状态>`

## 复发追踪

| 日期 | 功能 | 触发条件 | 处置 |
|------|------|---------|------|
| | | | |

## 修订历史

| 日期 | 修订者 | 变更 |
|------|--------|------|
| | | |
```

### 3.7 Pattern 贬值与退役

| 状态 | 触发条件 | 含义 |
|------|---------|------|
| `active` | 已接受，正常使用中 | 活跃模式 |
| `dormant` | 连续 3 个功能未触发此 Pattern | 休眠——可能已自然解决或项目环境变化 |
| `superseded` | 连续 6 个功能未触发，或被新 Pattern 覆盖 | 退役——通过 `supersededBy` 链接到新 Pattern |

Pattern 退役不删除文件，仅变更状态。退役的 Pattern 仍保留在 `_index.md` 中以备历史追溯。

---

## 4. Level 3: Instinct（本能规则）

### 4.1 定义

Instinct 是从 Pattern 转化而来的系统级规则，它被直接注入到 Agent 的行为指导文件中（AGENTS.md / CLAUDE.md / CODEX.md / state-machine.md），使 Agent 在每次执行时自动遵守，不再需要人类每次提醒。

本能意味着"系统已经学会，不再需要人类记住"。

### 4.2 来源

- 由 Pattern 晋升而来（最常见路径，占 ≥80%）
- 由人类直接制定（罕见，通常是在项目初始化或重大事故后）

### 4.3 晋升硬性条件（必须全部满足）

| # | 条件 | 验证方式 |
|---|------|---------|
| 1 | 源 Pattern 状态为 `active` 且已存在 ≥30 天 | 检查 `proposedAt` 与当前日期差值 |
| 2 | 源 Pattern 的 `recurrenceCount` ≥ 3（即在 ≥3 个功能中确认有效） | 检查 `recurrenceCount` 字段 |
| 3 | Pattern 的解决方案中有明确的、**可机械执行**的规则 | 规则可写为 "当 X 时，必须检查/执行 Y" 的形式 |
| 4 | 规则**不依赖**上下文判断 | 规则不包含 "评估"、"判断"、"适当的" 等主观词汇 |

### 4.4 晋升反条件（以下任何一条成立则**不能**晋升为 Instinct）

| # | 反条件 | 示例 |
|---|--------|------|
| 1 | 规则需要人类判断力 | "评估此技术栈是否适合项目" — 需要上下文 |
| 2 | 规则依赖外部系统的状态 | "当 API 可用时" — 不可靠的依赖 |
| 3 | 规则可能因项目类型不同而变化 | "对于 Web 项目应该 X，对于 CLI 项目应该 Y" |
| 4 | 规则的误报成本高（假阳性会导致严重后果） | "自动拒绝所有未在提案中声明依赖的 import" — 可能阻塞紧急修复 |
| 5 | 两个 Pattern 的 Instinct 互相冲突 | Pattern A 说"必须提前声明所有文件"，Pattern B 说"允许实现中创建测试文件" |

### 4.5 人工确认流程（学习型 Checkpoint 格式）

Instinct 是最高级别的经验沉淀——它直接修改 Agent 的行为准则。晋升必须经过人工确认，且**必须由人类执行写入操作**。

---

<div class="checkpoint-card" style="border: 2px solid #d4a574; border-radius: 12px; padding: 20px; margin: 16px 0;">

### 学习型 Checkpoint: Instinct 晋升与注入审批

<h4>📋 背景 (Context)</h4>

此时发生了什么：
- 源 Pattern `<pattern-name>` 已激活 ≥30 天，在 ≥3 个功能中确认有效
- Pattern 的解决方案中包含可机械执行的规则
- 经验管道生成了 `instincts/<instinct-name>.md` 提案（status: `proposed`）
- 已指定注入目标文件、注入位置和精确措辞

关联的前序决策：
- 源 Pattern 在 `<acceptedAt>` 被接受（决策人：`<confirmedBy>`）
- 源 Pattern 的复发追踪记录了 ≥3 次确认有效的触发
- 源 Lessons 可追溯至具体功能的 retro

不做出决策的后果：
- 此类问题将继续依赖 Agent 的记忆和人类的每次提醒
- "经验在文档里，但 Agent 不会主动查"——Pattern 沦为摆设
- 每次新功能启动时，编排 Agent 可能重复犯同样的错

<h4>🔍 分析 (Analysis)</h4>

Agent 已考虑的因素：
- 规则的机械可执行性：已用"当 X 时，必须 Y"格式重写规则，确保不依赖判断
- 注入位置的合适性：已检查目标文件的当前内容，确保不会与现有规则冲突
- 副作用分析：已模拟 3 个典型功能场景，检查此规则是否会产生误报或过度限制
- 冲突检查：已与所有活跃 Instincts 交叉比对，确认无冲突
- 逆转成本：已定义明确的逆转条件，确保未来可以安全移除

已排除的方案及理由：
- 保留为 Pattern（不晋升）：规则已满足所有晋升条件，延迟不会增加信息
- 注入但不写入系统文件（仅在 Pattern 中描述）：Agent 不会主动查询 Pattern，效果等同于不存在
- 合并到其他 Instinct：规则独立且与其他 Instinct 有不同的触发条件，合并会造成职责混乱

<h4>📚 经验课堂 (Learning)</h4>

> **有经验的工程管理者会怎么想？**
>
> Instinct 是最危险也最有价值的演化层级。危险在于：错误的 Instinct 会让整个系统的行为偏差，而且偏差是自动化的、系统性的。有价值在于：正确的 Instinct 是团队无需额外成本的"肌肉记忆"。
>
> 关键原则：
> - **"写下来"和"执行"之间有巨大的鸿沟。** 大多数组织经验的问题不是缺乏文档，而是文档在执行时不会被主动查阅。Instinct 的使命是填平这个鸿沟。
> - **Instinct 的维护成本 > Pattern > Lesson。** 每增加一条 Instinct，就增加了一个可能产生误报的自动化检查点。保持 Instinct 数量精简（建议 ≤20 条）。
> - **每一条 Instinct 都应该有"逆转条件"。** 如果没有定义"什么情况下应该移除此规则"，那说明你还没有充分理解它的边界。
> - **参考：Google's "Testing on the Toilet" 和 Amazon's "Good Mechanisms"** ——好的机制是"即使执行者换了，行为也不会变"。

<h4>🎯 选项 (Options)</h4>

| | 方案 A: 批准并注入 | 方案 B: 修改规则措辞 | 方案 C: 拒绝，保持为 Pattern |
|---|---|---|---|
| 简述 | 人类执行注入，Instinct 状态变为 `active`，源 Pattern 更新 `instinctCandidate: true` | 调整规则的措辞、注入位置或触发条件 | Instinct 文件标记 `rejected`，源 Pattern 保持 `active`，问题继续由人类提醒 |
| ✅ 优势 | 系统从此自动执行，零人工记忆成本 | 确保规则精确无歧义 | 避免可能不精确的自动规则 |
| ⚠️ 风险 | 规则的副作用可能在边缘场景中暴露 | 多轮沟通，延迟生效 | 同类问题将在后续功能中继续出现 |
| 💰 成本 | 低（一次性注入） | 中 | 高（每次功能复发） |
| 适合谁 | 规则措辞精确、注入位置明确、无已知冲突 | 对规则的措辞或注入位置有疑虑 | 规则仍需人类判断，或证据不足以支持自动化 |

<h4>⭐ 推荐 (Recommendation)</h4>

<div style="background:#1a2e1a; border:1px solid #27ae60; border-radius:8px; padding:12px; margin:8px 0;">

**推荐方案：** 基于规则的确定性和副作用大小决定。

- 若规则可写为确定性的检查脚本（如 "检查 OpenSpec 是否包含 '敏感数据策略' 节"）→ 推荐 **方案 A**
- 若规则的注入位置可能与现有内容产生风格冲突 → 推荐 **方案 B**（先调整措辞）
- 若规则的"可机械执行"存疑（如规则的触发条件有 ≥2 种合理解读）→ 推荐 **方案 C**

**推理链路：** Instinct 必须在"零误报"和"全覆盖"之间取得平衡。优先保证零误报——一条产生误报的 Instinct 会侵蚀 Agent 对系统规则的信任。

**何时应推翻此推荐：** 若此问题在当前活跃功能中造成了 P0 级事件，可接受略微宽泛的规则，但必须加注 `review-in-30-days` 标签并在 30 天后重新评估。

</div>

<h4>✋ 你的决策 (Decision)</h4>

请选择：`[ ] 方案 A / [ ] 方案 B / [ ] 方案 C`

若选方案 A，请指定由谁执行注入：`[ ] 人类手动 / [ ] Agent 提交 PR（人类合入）`

若选方案 B，请说明需要修改的内容：`______`

</div>

---

### 4.6 文件格式模板

存储路径：`workflow/experience/instincts/<instinct-name>.md`

```markdown
---
instinctId: INS-<序号>
instinctName: <kebab-case 名称>
status: proposed | active | superseded
proposedAt: <ISO 8601 时间戳>
activatedAt: null
proposedBy: claude | codex | human
confirmedBy: null
signedOffBy: null
sourcePattern: PTN-<序号>
deterministicCheck: <确定性检查方式的描述>
injectionTargets:
  - file: AGENTS.md
    section: "## 实现规则" 或新增节
    lineRange: null
    injectedRule: |
      <注入的规则原文>
  - file: workflow/state-machine.md
    section: "## S5 Implementation"
    lineRange: null
    injectedRule: |
      <注入的规则原文>
---

# <Instinct 标题>

## 规则

> 一句话规则。可以直接复制粘贴到 Agent 指令中。必须使用"当…时，必须…"的格式。

**规则：** <清晰、可执行的规则语句>

## 确定性检查方式

> 此规则如何在不依赖 LLM 判断的情况下自动验证？

**检查方式：** <描述检查脚本、grep 模式、文件存在性检查等确定性手段>

示例：
- 检查脚本: `grep -q "敏感数据策略" <feature-folder>/01-openspec-proposal.md`
- 文件存在性: `test -f workflow/features/*/02-grill-me-report.md`
- 字段检查: `jq '.gates[0].status' feature-state.json`

## 来源

> 此规则从哪个 Pattern 演变而来？

源 Pattern: [<pattern-name>](../patterns/<pattern-name>.md)

源 Lessons（追溯到原始事件）：[LSN-xxx-001](../lessons/xxx/lesson-001.md), [LSN-xxx-002](../lessons/xxx/lesson-002.md)

## 为什么这是本能而非模式

> 说明为什么这个规则不再需要人类每次判断——它已成为系统的默认行为。

1. **证据充分：** 已在 ≥3 个功能中验证有效，无假阳性记录
2. **可机械执行：** 规则的触发和验证不依赖上下文判断
3. **失败模式已知：** 已定义明确的逆转条件和副作用监控

## 注入记录

> 此规则已写入以下文件：

| 文件 | 注入位置（节/行号） | 注入日期 | 执行者 | 方式 |
|------|-------------------|---------|--------|------|
| AGENTS.md | 新增节 "## 敏感数据策略" | 2026-06-16 | human:oldmanpushbike | 手动写入 |

## 注入规则原文

> 以下是实际注入到目标文件中的规则文本块。

```markdown
## 敏感数据策略（Instinct: INS-001）

**规则：任何涉及外部 API、数据库、第三方服务的功能，
在 Gate 1（OpenSpec）中必须包含"敏感数据策略"节，
明确以下内容：**
1. 凭证存储方式（环境变量 / Secret Manager / KMS）
2. 凭证轮换策略（手动 / 自动 / 无轮换）
3. 访问控制（谁/哪个服务可以读取凭证）

若 Gate 1 检查发现缺失此节 → 功能不得进入 S2。
```

## 副作用监控

> 此规则是否产生过误报或不当限制？每次功能完成后评估。

| 日期 | 功能 | 报告者 | 问题描述 | 处置 |
|------|------|--------|---------|------|
| | | | | |

## 逆转条件

> 什么情况下应撤销此 Instinct？以下条件任一满足即触发重新评估。

- 条件 1: 连续 3 个功能的"敏感数据策略"节均为空或仅填写 "N/A"，说明规则过度覆盖
- 条件 2: 规则被确认为某个功能的阻塞根因（非合理阻塞）
- 条件 3: 系统文件结构变更，注入位置不再存在

## 修订历史

| 日期 | 修订者 | 变更 |
|------|--------|------|
| | | |
```

### 4.7 注入目标优先级

Instinct 可以注入到以下系统文件，按影响力从高到低排列：

| 优先级 | 文件 | 适合的规则类型 | 示例 |
|--------|------|--------------|------|
| 1 | `AGENTS.md` | 两个 Agent 都必须遵守的**共享契约** | "所有涉及凭证的功能必须在 OpenSpec 中声明敏感数据策略" |
| 2 | `workflow/state-machine.md` | 特定状态的**退出条件**或 fallback 规则 | "S5 退出前必须检查是否存在未声明的外部依赖" |
| 3 | `workflow/fallback-matrix.md` | 新增**降级场景**或修改降级策略 | "当 MCP 不可达且 grill-me 未完成时，新增 X 降级路径" |
| 4 | `CLAUDE.md` | Claude 特有的**编排/审查行为** | "Claude 在 S2 审查时必须主动检查 X、Y、Z" |
| 5 | `CODEX.md` | Codex 特有的**编排/审查行为** | "Codex 在 S5 实现时必须遵循 X 命名规范" |
| 6 | `workflow/templates/*.md` | 模板中新增的**必填字段或检查项** | "01-openspec-proposal.md 新增 '敏感数据策略' 节" |
| 7 | `workflow/feature-state.schema.json` | **数据结构层面**的硬约束 | "gate 字段新增 credentialStrategyDefined 必填布尔值" |

### 4.8 Instinct 注入的防护规则

防止 AI 自我修改行为准则的安全机制：

1. **AI 不得自行写入 Instinct。** AI 只能生成 Instinct 提案文件和 PR，人类必须执行实际写入。
2. **Instinct 的 `signedOffBy` 字段必须填写真实人类标识。** 不能是 "claude" 或 "codex"。
3. **每次注入必须记录在 Instinct 文件的"注入记录"表格中。** 可追溯。
4. **Instinct 注入 AGENTS.md 后，AGENTS.md 的 diff 必须在 Code Review 中额外检查。** 防止一条 Instinct 无意中削弱了另一条。

---

## 5. 管道触发机制

### 5.1 自动触发

以下事件自动触发经验提取/晋升检查：

| 触发事件 | 动作 | 执行者 | 检查频率 |
|---------|------|--------|---------|
| 功能进入 S8 | 扫描 `07-task-retro.md`，提取 Lesson 草稿 | `extract-lessons.sh`（零 LLM） | 每次 S8 |
| 功能进入 S9 | 评分引擎运行，若某维度 < 基线 20 分且连续 ≥3 个功能 → 标记 `needs-pattern-review` | 评分引擎 | 每次 S9 |
| 新 Lesson 创建 | 检查是否与已有 Lesson 共享 ≥2 个 tags → 若 ≥2 个来自不同功能的 Lesson 匹配 → 提案 Pattern 草稿 | `extract-lessons.sh` | 每次新 Lesson |
| Pattern 年龄 ≥30 天 | 检查 `recurrenceCount` 是否 ≥3 → 若满足且 `instinctCandidate` 为 true → 生成 Instinct 提案 | 月度巡检脚本 | 每月 1 次 |
| Lesson draft 超过 60 天 | 标记 `stale`，生成提醒（写入 `_index.md` 的 warnings 区域） | 月度巡检脚本 | 每月 1 次 |
| Pattern dormant 超过 90 天 | 标记 `superseded`，记录退役原因 | 月度巡检脚本 | 每月 1 次 |

### 5.2 人工触发

人类在任何时候可以执行以下操作（不受自动条件限制）：

- 直接创建 Lesson / Pattern / Instinct
- 直接将 Lesson 晋升为 Pattern（跳过 ≥2 个限制，但需在 Pattern 文件中注明 `skipCondition: "human-override"` 和理由）
- 拒绝任何自动提案（设置 status 为 `rejected` + 填写拒绝理由）
- 手动触发经验管道巡检（运行 `extract-lessons.sh --force`）
- 手动退役 Pattern 或 Instinct

---

## 6. 经验提取 Checklist

以下 Checklist 用于在每次功能进入 S8 时系统性地提取经验。它既是自动脚本的检查清单，也是人类审阅 Lesson 时的参考。

### 6.1 Lesson 提取 Checklist

**从 retro 中提取时，逐项检查：**

- [ ] **R1 — 失败事件全覆盖：** `07-task-retro.md` 的 "What Failed Or Slowed Us Down" 中每个非空列表项是否都有对应的 Lesson？
- [ ] **R2 — 工具/Agent 异常覆盖：** "Tool / Agent Notes" 中标注了异常（关键词：失败/不可用/降级/超时/误判）的条目是否已提取为 Lesson？
- [ ] **R3 — 模式发现覆盖：** "Reusable Pattern Found" 若回答了 "Should this become..."，是否已生成对应的 Lesson 并填写了 "关联 Pattern 候选"？
- [ ] **R4 — 知识传递覆盖：** "Knowledge To Carry Forward" 的内容是否已复制到至少 1 个 Lesson 的 "学到了什么" 字段？
- [ ] **R5 — 根因深度：** 每个 Lesson 的 "为什么会发生" 是否至少追问了 1 层根因（不是 "Agent 忘记检查了" 就停——要问 "为什么检查没有被系统化？"）？
- [ ] **R6 — 建议可操作性：** 每个 Lesson 的 "应该改变什么" 中的建议是否都是可验证的（完成后可以打勾）？

### 6.2 Lesson 质量 Checklist

**人类审阅 draft Lesson 时，逐项检查：**

- [ ] **Q1 — Severity 准确性：** severity 是否已从默认 P3 修正为真实严重度？
  - P0: 导致数据丢失、安全漏洞、或 2h+ 的阻塞
  - P1: 导致返工、需要人类介入、或技术债务积累
  - P2: 造成不便但未阻塞流程
  - P3: 打磨级别，仅作为改进建议
- [ ] **Q2 — Tags 完整性：** tags 是否包含至少 2 个维度（如：`[security, ops]` 比单独的 `[security]` 更容易被 Pattern 匹配引擎发现）？
- [ ] **Q3 — 教训可迁移性：** "学到了什么" 是否不包含特定功能名称？（"在 Werewolf 功能中应该 X" → 不合格；"涉及实时通信的功能应该 X" → 合格）
- [ ] **Q4 — 关联准确性：** "关联 Pattern 候选" 中的关联是否准确？是否遗漏了已有 Pattern 的关联？
- [ ] **Q5 — 无重复：** 是否与同一功能下的已有 Lesson 有 ≥70% 的内容重叠？如有，应合并而非创建新 Lesson。

### 6.3 Pattern 晋升 Checklist

**晋升前逐项检查（自动脚本 + 人工复核）：**

- [ ] **P1 — 跨功能验证：** 源 Lessons 的去重 `featureId` ≥ 2？
- [ ] **P2 — Severity 验证：** 至少 1 个源 Lesson severity ≥ P1？
- [ ] **P3 — 标签交叉匹配：** 源 Lessons 的 tags 交集 ≥ 2 个？（如 Lesson A tags: `[llm, security]`, Lesson B tags: `[security, credentials, api]` → 交集 = `[security]`，不满足 → 需人工判断）
- [ ] **P4 — 证据表完整：** Pattern 的 "关联证据" 表是否包含所有源 Lesson？
- [ ] **P5 — 解决方案分层：** "解决方案" 是否包含主动措施、反应措施、补救措施三层？
- [ ] **P6 — Instinct 候选评估：** "Instinct 候选" 是否已认真评估（而非默认 "否"）？
- [ ] **P7 — 命名规范：** patternName 是否使用 kebab-case，是否清晰描述问题而非解决方案？（好的: `credential-leakage-in-openspec-gap`，不好的: `add-credential-section`）

### 6.4 Instinct 晋升 Checklist

**晋升前逐项检查（人工必须逐条确认）：**

- [ ] **I1 — Pattern 成熟度：** 源 Pattern 的 `status` 为 `active` 且 ≥30 天？
- [ ] **I2 — 复发验证：** 源 Pattern 的 `recurrenceCount` ≥ 3？
- [ ] **I3 — 可机械执行：** 规则可写为 "当 X 时，必须 Y" 且不包含 "评估"、"判断"、"适当的" 等主观词汇？
- [ ] **I4 — 确定性检查：** 规则有明确的、可脚本化的检查方式（grep / test -f / jq 字段检查）？
- [ ] **I5 — 无冲突：** 已与所有活跃 Instincts 交叉比对，确认无语义冲突？
- [ ] **I6 — 注入位置精确：** 注入目标文件、节名称、插入位置已明确指定？
- [ ] **I7 — 逆转条件：** 已定义至少 1 个可验证的逆转条件？
- [ ] **I8 — 副作用模拟：** 已模拟 3 个典型功能场景，检查规则的误报率和漏报率？
- [ ] **I9 — 人类签核：** `signedOffBy` 字段已填写真实人类标识？

### 6.5 定期健康检查

**月度巡检脚本执行以下检查：**

- [ ] **H1 — 孤儿 Lesson 扫描：** `status: draft` 且超过 60 天未审阅的 Lesson
- [ ] **H2 — 休眠 Pattern 扫描：** `status: active` 但超过 3 个功能未触发的 Pattern
- [ ] **H3 — 过期 Pattern 扫描：** `status: dormant` 超过 90 天的 Pattern（应退役）
- [ ] **H4 — 待审 Instinct 扫描：** `status: proposed` 超过 30 天的 Instinct 提案（应提醒）
- [ ] **H5 — 索引一致性：** `_index.md` 与实际文件是否一致？
- [ ] **H6 — 交叉引用完整性：** Lesson 的 `relatedPatterns` 和 Pattern 的 `sourceLessons` 是否双向一致？

---

## 7. 存储结构

```
workflow/experience/
├── pipeline.md                          # 本文件 — 管道定义
├── extract-lessons.sh                   # 自动提取脚本（待实现）
├── monthly-health-check.sh              # 月度巡检脚本（待实现）
│
├── lessons/                             # Level 1: 教训
│   ├── .gitkeep
│   ├── <feature-id-1>/
│   │   ├── lesson-001.md
│   │   ├── lesson-002.md
│   │   └── lesson-003.md
│   ├── <feature-id-2>/
│   │   └── lesson-001.md
│   └── _index.md                        # 所有 Lessons 的可搜索索引（自动生成）
│
├── patterns/                            # Level 2: 模式
│   ├── .gitkeep
│   ├── <pattern-name-1>.md
│   ├── <pattern-name-2>.md
│   └── _index.md                        # 所有 Patterns 的索引（自动生成）
│
└── instincts/                           # Level 3: 本能规则
    ├── .gitkeep
    ├── <instinct-name-1>.md
    ├── <instinct-name-2>.md
    └── _index.md                        # 所有 Instincts 的索引（自动生成）
```

### 7.1 索引文件格式 (`_index.md`)

每个目录下的 `_index.md` 由脚本自动生成，人类不应手动编辑。

#### 7.1.1 Lessons 索引

```markdown
# Lessons 索引

> 自动生成于 `<timestamp>`
> 总计: N 个（draft: X, reviewed: Y, promoted: Z, archived: W）

| ID | 功能 | 摘要 | 严重度 | Tags | 状态 | 关联 Pattern |
|----|------|------|--------|------|------|-------------|
| LSN-xxx-001 | feature-a | ... | P0 | a,b | reviewed | PTN-001 |
| LSN-xxx-002 | feature-b | ... | P1 | a,c | draft | - |

## Warnings

> 以下 Lesson 需要关注：

- `LSN-xxx-003`: draft 超过 60 天未审阅（创建于 2026-04-01）
```

#### 7.1.2 Patterns 索引

```markdown
# Patterns 索引

> 自动生成于 `<timestamp>`
> 总计: N 个（proposed: X, active: Y, dormant: Z, superseded: W）

| ID | 名称 | 状态 | 源 Lessons | 复发次数 | 最后触发功能 | Instinct 候选 |
|----|------|------|-----------|---------|------------|-------------|
| PTN-001 | xxx | active | 3 | 5 | feature-c | INS-001 |

## Warnings

> 以下 Pattern 需要关注：

- `PTN-002`: dormant 状态已 92 天，建议退役
```

#### 7.1.3 Instincts 索引

```markdown
# Instincts 索引

> 自动生成于 `<timestamp>`
> 总计: N 个（proposed: X, active: Y, superseded: Z）

| ID | 名称 | 状态 | 源 Pattern | 注入目标 | 签核者 | 激活日期 |
|----|------|------|-----------|---------|--------|---------|
| INS-001 | xxx | active | PTN-001 | AGENTS.md | oldmanpushbike | 2026-06-16 |

## Warnings

> 以下 Instinct 需要关注：

- `INS-003`: proposed 已超过 30 天，等待人类签核
```

---

## 8. 与评分引擎的联动

### 8.1 评分引擎如何驱动经验管道

评分引擎的 7 个维度中，以下维度与经验管道直接联动：

| 评分维度 | 联动机制 | 触发条件 |
|---------|---------|---------|
| 审查深度 (ReviewDepth) | 若连续 3 个功能 < 40 分 → 生成 Pattern 提案："审查敷衍模式" | `consecutiveBelowBaseline >= 3` |
| 降级健康度 (DegradationHealth) | 同一 `fallbackEvent` 类型出现 ≥3 次 → 生成 Pattern 提案："X 降级复发模式" | 按 `eventType` 分组计数 ≥3 |
| 反馈效能 (FeedbackEfficacy) | 反馈注入后重试仍失败 → 对应 Lesson severity 自动提升为 P0 | `feedbackInjected = true AND retryCount = maxRetries AND status = failed` |
| 人工触点 (HumanTouch) | 某 gate 从未有过人类决策 → Lesson："门禁 X 缺乏人类把关" | 按 `humanDecisions[].gateId` 去重后某 gate 未出现 |
| 流转速度 (CycleVelocity) | S2→S3 或 S6→S7 过快（≤5min）→ Lesson："审查/修正可能跳过了" | 转移时长 ≤ 0.083h |

### 8.2 经验沉淀率维度（Experience Precipitation Rate, EPR）

经验沉淀率是评分引擎的一个**派生维度**（不单独加权，但作为健康指标输出到评分报告中）。它度量经验管道的"吞吐量"——有多少教训真正进入了系统。

#### 8.2.1 EPR 公式

```
EPR = (P_active + I_active) / (L_total + 1) * 100

其中:
  L_total = 所有功能的 Lesson 总数（包括 draft/reviewed/promoted）
  P_active = 当前活跃 Pattern 的数量（status = active）
  I_active = 当前活跃 Instinct 的数量（status = active）
  +1 防止除零
```

#### 8.2.2 EPR 阈值

| EPR 范围 | 含义 | 建议动作 |
|---------|------|---------|
| ≥ 30% | 优秀：经验在有效向上流动 | 保持 |
| 15% - 29% | 健康：有沉淀但可加速 | 检查是否有 draft Lesson 积压 |
| 5% - 14% | 警告：大量 Lesson 未晋升 | 安排 Pattern 归纳会议 |
| < 5% | 危险：经验管道形同虚设 | 紧急：检查 retro 质量 + 管道是否运行 |

#### 8.2.3 EPR 趋势

除瞬时值外，评分引擎还追踪 EPR 的趋势（在评分输出 JSON 的 `trends` 部分）：

```
EPRTrend = (当前 EPR - 前 3 个功能的平均 EPR) / 前 3 个功能的平均 EPR * 100

若 EPRTrend > 20% → 标记 positive
若 EPRTrend < -20% → 标记 declining → warning
否则 → stable
```

#### 8.2.4 EPR 输出示例

在评分输出 JSON 中增加 `experiencePipeline` 字段：

```json
{
  "experiencePipeline": {
    "epr": 22.5,
    "eprTrend": "stable",
    "eprDelta": 3.2,
    "breakdown": {
      "lessonsTotal": 15,
      "lessonsDraft": 8,
      "lessonsReviewed": 5,
      "lessonsPromoted": 2,
      "patternsActive": 3,
      "patternsDormant": 1,
      "patternsSuperseded": 1,
      "instinctsActive": 1,
      "instinctsProposed": 1
    },
    "warnings": [
      "8 个 draft Lesson 超过 30 天未审阅",
      "Pattern 'code-review-rubber-stamp' 处于 dormant 状态已超过 90 天，建议退役"
    ]
  }
}
```

### 8.3 联动架构图

```
┌──────────────────────────────────────────────────────────┐
│                      联动全景                              │
│                                                          │
│  feature-state.json (多个功能)                            │
│        │                                                 │
│        ├──→ 评分引擎 (7 维评分)                            │
│        │       │                                         │
│        │       ├──→ dashboard.html (人类可视化)             │
│        │       ├──→ gate-check.sh (CI 门禁)               │
│        │       └──→ 低分维度 → Pattern 提案                │
│        │                                                 │
│        └──→ 07-task-retro.md                              │
│                │                                         │
│                └──→ extract-lessons.sh                     │
│                        │                                 │
│                        ├──→ Lesson 草稿                    │
│                        ├──→ 标签匹配 → Pattern 提案         │
│                        └──→ 经验沉淀率 (EPR) 回填评分报告    │
│                                                          │
│  月度巡检脚本                                              │
│        │                                                 │
│        ├──→ 检查 Pattern 年龄 → Instinct 提案              │
│        ├──→ 检查 draft Lesson 过期 → 提醒                 │
│        └──→ 更新 _index.md                                │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

### 8.4 管道健康仪表板

评分引擎的 `dashboard.html` 增加"经验管道"面板，展示：

1. **EPR 仪表盘：** 当前 EPR 值 + 趋势箭头 + 目标线（≥15% 为绿色区域）
2. **三级数量柱状图：** Lesson 总数 / Pattern 活跃数 / Instinct 活跃数
3. **积压警告：** draft Lesson 超过 60 天的数量
4. **最近晋升：** 最近 30 天内晋升的 Pattern / Instinct
5. **跨功能热力图：** 哪些 tags 的 Lesson 最多（= 哪些问题最频繁）

---

## 9. 示例：一条完整的进化链

以下示例展示了从单次失败到系统级免疫的完整路径。

### Step 1: Lesson（从狼人杀项目的 retro 提取）

**文件：** `lessons/ai-werewolf/lesson-001.md`

```markdown
---
lessonId: LSN-ai-werewolf-001
featureId: ai-werewolf
taskId: task-3-llm-integration
source: 07-task-retro.md
status: reviewed
severity: P1
tags: [llm, api-proxy, security, credentials, frontend]
relatedGates: [gate-1, gate-5]
relatedPatterns: []
---

# LLM API Key 在前端代码中短暂暴露

## 发生了什么
在 S5 实现 LLM 调用时，API Key 最初写在了前端环境变量中，
在 Codex 审查（S6）时被发现并修正为 Next.js Route Handler 代理。

## 为什么会发生
OpenSpec 中没有明确 API Key 的存储策略。实现者（Claude）按"最快跑通"原则
先放在前端 env，计划后续重构但未标注 TODO。根本原因：模板缺少"敏感数据策略"节。

## 学到了什么
**教训：涉及凭证的架构决策必须在 OpenSpec 阶段明确，不能在实现中临时决定。**

## 应该改变什么
- [ ] 在 `01-openspec-proposal.md` 模板中增加"敏感数据策略"节
- [ ] 在 Gate 1 检查项中增加"是否涉及凭证"的检查
```

### Step 2: Pattern（跨功能归纳）

**触发：** 2 个不同功能的 Lesson 都涉及凭证/敏感数据在实现中暴露。自动标签匹配（tags: `[security, credentials]`）触发提案。

**文件：** `patterns/credential-leakage-in-openspec-gap.md`

```markdown
---
patternId: PTN-001
patternName: credential-leakage-in-openspec-gap
status: active
proposedAt: 2026-02-15T10:00:00Z
acceptedAt: 2026-02-18T14:00:00Z
proposedBy: claude
confirmedBy: oldmanpushbike
sourceLessons: [LSN-ai-werewolf-001, LSN-gate-layer-v2-003]
sourceScores: [{dimension: "reviewDepth", trend: "declining", consecutiveBelowBaseline: 2}]
tags: [security, credentials, openspec, template]
instinctCandidate: true
instinctName: openspec-must-define-credential-strategy
recurrenceCount: 2
---

# OpenSpec 遗漏凭证策略导致实现中暴露

## 症状
- S5 实现时发现 API Key / Token / 数据库密码的存储方式未定义
- 实现者自行决定（倾向于最快路径：环境变量或硬编码）
- 在 S6 审查时被发现并返工（相当于浪费了 S5 的部分工作量）

## 根因
OpenSpec 模板中没有"凭证与敏感数据策略"必填节。由于模板是生成提案的骨架，
缺失此节意味着 Agent 在 S1 阶段不会主动考虑凭证问题。

## 触发条件
- 功能涉及外部 API（LLM、支付、地图等）
- 功能涉及数据库连接
- 功能需要第三方服务的 Token/Key

## 解决方案
1. **主动措施（预防）：** 在 `01-openspec-proposal.md` 模板中增加"敏感数据策略"节
2. **反应措施（检测）：** Gate 1 检查 OpenSpec 是否包含 credential 相关关键词
3. **补救措施（修复）：** S6 审查增加"敏感数据流"专项检查

## Instinct 候选
- [x] 是，建议 Instinct: openspec-must-define-credential-strategy
```

### Step 3: Instinct（注入系统）

**触发：** PTN-001 在 5 个功能中确认有效（`recurrenceCount: 5`），已激活超过 30 天。月度巡检脚本建议晋升。人类确认。

**文件：** `instincts/openspec-must-define-credential-strategy.md`

```markdown
---
instinctId: INS-001
instinctName: openspec-must-define-credential-strategy
status: active
proposedAt: 2026-05-01T09:00:00Z
activatedAt: 2026-05-15T16:00:00Z
proposedBy: claude
confirmedBy: oldmanpushbike
signedOffBy: oldmanpushbike
sourcePattern: PTN-001
deterministicCheck: "grep -q '敏感数据策略' <feature-folder>/01-openspec-proposal.md"
injectionTargets:
  - file: workflow/templates/01-openspec-proposal.md
    section: "新增节（在 'API 契约' 之后）"
    injectedRule: |
      ## 敏感数据策略
      
      > 若本功能涉及外部 API、数据库、第三方服务或任何形式的凭证，必须填写以下内容。
      > 若完全不涉及，填写 "N/A — 本功能不涉及敏感数据"。
      
      - **凭证清单：** <列出所有需要的凭证类型（API Key / DB Password / OAuth Token 等）>
      - **存储方式：** <环境变量 / Secret Manager / KMS / Vault / 其他>
      - **轮换策略：** <手动轮换 / 自动轮换 / 无轮换（原因）>
      - **访问控制：** <谁/哪个服务可以读取凭证？运行时还是构建时？>
  - file: AGENTS.md
    section: "## 实现规则"
    injectedRule: |
      **规则：涉及外部 API、数据库、第三方服务的功能，在 Gate 1 的 OpenSpec 中必须包含"敏感数据策略"节。若缺失，功能不得进入 S2。**
---

## 规则
**规则：任何涉及外部 API、数据库、第三方服务的 OpenSpec 提案，
必须在"敏感数据策略"节中明确凭证存储方式、轮换策略和访问控制。
若缺失此节，功能不得进入 S2，直至补充完整且经人类确认。**
```

### 进化链总结

```
LSN-ai-werewolf-001 (P1) ─┐
                           ├──→ PTN-001 (跨功能归纳) ──→ INS-001 (注入 AGENTS.md + OpenSpec 模板)
LSN-gate-layer-v2-003 (P0) ┘        │
                                     │ 在 5 个后续功能中触发验证
                                     │ 每次触发 → PTN-001.recurrenceCount++
                                     │ 达到 5 次后 → 人类签核 → INS-001.active
                                     │
                              EPR 贡献: L_total=15, P_active=3, I_active=1 → EPR=25%
```

---

## 10. 实施路线图

| 阶段 | 内容 | 产物 | 状态 |
|------|------|------|------|
| Phase 1 | 目录结构 + .gitkeep + 本文档 | `pipeline.md` | ✅ 完成 |
| Phase 2 | `extract-lessons.sh` 自动提取脚本 | 零 LLM Shell 脚本 | 📋 待实现 |
| Phase 3 | Lesson 标签匹配引擎（tag-based Pattern 提案） | 集成到 extract-lessons.sh | 📋 待实现 |
| Phase 4 | 月度巡检脚本（Pattern 年龄检查 + draft 过期提醒） | `monthly-health-check.sh` | 📋 待实现 |
| Phase 5 | 评分引擎联动（低分维度 → Pattern 提案 + EPR 计算） | `score.py` 扩展 | 📋 待实现 |
| Phase 6 | Dashboard "经验管道"面板（EPR 仪表盘 + 三级柱状图） | `dashboard.html` 扩展 | 📋 待实现 |
| Phase 7 | Instinct 注入自动化检查（CI 中验证注入一致性） | CI 脚本 | 📋 待实现 |

---

## 附录 A: 术语表

| 术语 | 英文 | 定义 |
|------|------|------|
| 教训 | Lesson | 经验管道的最小单元，记录单次失败及其根因 |
| 模式 | Pattern | 跨功能的抽象问题描述 + 系统化解决方案 |
| 本能规则 | Instinct | 注入系统文件的确定性规则，Agent 自动遵守 |
| 经验沉淀率 | EPR (Experience Precipitation Rate) | 度量 Lesson → Pattern → Instinct 转化效率的指标 |
| 学习型 Checkpoint | Learning Checkpoint | 人类介入时的六段结构化输出（背景/分析/经验课堂/选项/推荐/决策） |
| 晋升 | Promotion | 经验从低层级向高层级的正式转化，需人工确认 |
| 退役 | Supersession | Pattern 或 Instinct 因不再适用而被标记为废弃，文件保留 |

## 附录 B: 文件命名规范

| 文件类型 | 命名规范 | 示例 |
|---------|---------|------|
| Lesson | `lesson-<三位序号>.md` | `lesson-001.md` |
| Pattern | `<kebab-case 问题描述>.md` | `credential-leakage-in-openspec-gap.md` |
| Instinct | `<kebab-case 规则关键词>.md` | `openspec-must-define-credential-strategy.md` |
| 索引 | `_index.md` | `_index.md` |

命名原则：
- Lesson 编号仅在该功能文件夹内唯一，跨功能通过 `lessonId` 全局唯一（`LSN-<feature-id>-<序号>`）
- Pattern 和 Instinct 的名称应描述**问题而非解决方案**（因为解决方案可能随技术栈变化，问题不变）
- 所有文件名仅使用小写字母、数字和连字符
