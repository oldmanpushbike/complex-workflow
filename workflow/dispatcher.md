# 调度器（Dispatcher）Agent 指令

> **文件系统是真相源。产物文件在不在比模型自报更可靠。**

本文件是调度器 Agent 的完整指令集。它在每个 Agent 会话启动时被加载（常驻层，约 6KB），将主 Agent 会话从「自主决策者」退化为「确定性执行器」。

## 调度器定位

调度器是工作流的**交通警察**，不是实现者。它只做五件事：

1. **读状态**——从 `workflow/features/<feature-id>/feature-state.json` 获取当前状态
2. **查门禁**——调用 `workflow/scripts/gate-check.sh` 做确定性检查
3. **验转换**——对照 `workflow/state-machine.md` 判断下一个合法状态
4. **生成路由**——输出下一步动作指令（编排者 / 挑战者 / 人类）
5. **检测回归**——发现「另一个 Agent 回来了」的信号，触发交叉验证

调度器**不做**的事：写代码、写规格、写审查、改制品。它只做三件事：读、检、路由。

---

## 零、设计原则

1. **决策最小化。** 调度器不做设计决策——它只读取状态、路由动作、触发检查。
2. **fail-closed。** 任何不确定状态 → 停止 → 要求人类或门禁检查介入。
3. **文件优先。** 永远先读 `feature-state.json`，再读 Markdown 制品。JSON 是结构化的、可被脚本校验的；Markdown 是辅助的。
4. **零幻读。** 每次路由决策前必须重新读取 `feature-state.json`，不得依赖会话记忆。
5. **gate-check.sh 优先。** 脚本的输出优先级高于调度器的模型推理。若 gate-check 说 fail，即使模型认为「看起来都对」，也必须按 fail 处理。
6. **无实现。** 调度器自身不写任何代码、规格、审查——只做路由和状态更新。

---

## 一、启动序列（每次会话必须执行）

### Step 0：读取常驻层

```
1. 读取 workflow/dispatcher.md（本文件）
2. 读取 workflow/state-machine.md
3. 读取 workflow/fallback-matrix.md（若存在降级事件）
```

### Step 1：发现功能

```
1. 列出 workflow/features/ 下所有子目录
2. 对每个子目录，检查是否存在 feature-state.json
3. 若不存在任何功能文件夹或 feature-state.json：
   → 当前无活跃功能。询问人类是否启动新功能。
   → 若人类要求启动新功能，进入「新功能创建」流程（见第六节）。
```

### Step 2：读取状态文件

```
对每个存在的 workflow/features/<feature-id>/feature-state.json：
  1. 读取完整内容
  2. 提取以下关键字段：
     - currentState（当前状态，S0-S9）
     - orchestrator（编排者身份：codex | claude）
     - challenger（挑战者身份：codex | claude | manual | none）
     - mode（模式：dual-agent | single-agent）
     - codexStatus（Codex 可达性：reachable | unreachable | degraded | unknown）
     - claudeStatus（Claude 可达性：reachable | unreachable | degraded | unknown）
     - mcpStatus（MCP 状态：up | down | unknown）
     - gates[].status（7 个门禁各自的状态）
     - stateHistory（状态转换历史）
     - feedbackLoop（若存在反馈循环）
     - fallbackEvents（若存在降级事件）
  3. 用 workflow/feature-state.schema.json 进行心智模式校验
     （或直接调用 gate-check.sh --schema-only 做确定性校验）
  4. 验证 currentState 是否为合法枚举值（S0-S9）
  5. 验证 orchestrator 是否为合法值（codex | claude）
```

### Step 3：识别「我是谁」

```
比较 feature-state.json 中的 orchestrator 字段与当前 Agent 身份：

  情况 A：orchestrator == "claude" AND 当前会话是 Claude
    → 你是编排者。加载「编排者路由表」（第二节）。
    → 你的会话角色：确定性执行器（见第七节）。

  情况 B：orchestrator == "codex" AND 当前会话是 Claude
    → 你是挑战者 / 审查者。加载「挑战者路由表」（第二节）。
    → 你的会话角色：验证器（见第七节）。

  情况 C：orchestrator == "codex" AND 当前会话是 Codex
    → 你是编排者。加载「编排者路由表」。
    → 你的会话角色：确定性执行器。

  情况 D：orchestrator == "claude" AND 当前会话是 Codex
    → 你是挑战者 / 审查者。加载「挑战者路由表」。
    → 你的会话角色：验证器。

  情况 E：无法确定当前 Agent 身份
    → 输出「调度器身份不确定」，列出不确定原因。
    → 要求人类确认当前角色后再继续。
```

### Step 4：检测「另一个 Agent 是否回来了」

这是调度器最关键的动态检测能力。

```
IF mode == "single-agent" THEN
  执行回归检测：

  1. 确定「缺席方」是谁：
     - 读取 codexStatus 和 claudeStatus
     - 若 codexStatus == "unreachable" → 缺席方是 Codex
     - 若 claudeStatus == "unreachable" → 缺席方是 Claude

  2. 尝试联系缺席方：
     - 优先通过 MCP 发送简单健康检查（如 echo health-check）
     - 若 MCP 不可用，尝试 CLI 调用
     - 若 CLI 不可用，检查是否有新的交接文件被写入
       （workflow/handoffs/codex-to-claude.md 或 claude-to-codex.md）

  3. 判断结果：
     ┌─ 响应正常：
     │  ✅ 另一个 Agent 已回归！
     │  → 设置 mode = "dual-agent"
     │  → 设置缺席方 Status = "reachable"
     │  → 在 fallbackEvents 中记录 resolved，填写 resolvedAt
     │  → 进入「回归验证协议」（见第五节）
     │  → 不要自动重新分配任务——等待编排者指令
     │
     └─ 无响应 / 超时 / 错误：
        → 保持 single-agent 模式
        → 更新 lastChecked 时间戳
        → 继续当前降级协议

ELSE IF mode == "dual-agent" THEN
  执行可达性验证：

  1. 检查另一方是否仍然可达：
     - 尝试与另一方通信（MCP > CLI > 交接文件时间戳检测）

  2. 判断结果：
     ┌─ 响应正常：
     │  → 保持 mode = "dual-agent"
     │  → 双方 Status = "reachable"
     │
     └─ 无响应：
        → 触发降级事件 reviewer_unreachable 或 challenger_unreachable
          （具体类型取决于当前状态 S2 还是 S6）
        → 按照 workflow/fallback-matrix.md 执行对应降级协议
        → 设置 mode = "single-agent"
        → 设置不可达方 Status = "unreachable"
        → 在 fallbackEvents 中记录新事件
```

---

## 二、状态路由表

根据 `currentState` 和 Agent 角色，路由到正确的下一步动作。

### 编排者路由表

编排者拥有主干。以下每个状态都对应明确的动作和下一个目标状态。

| currentState | 本节状态含义 | 动作 | 下一个目标状态 | 关键产物 |
|---|---|---|---|---|
| S0 启动 | 功能刚刚创建，尚无规格 | 1. 创建功能文件夹<br>2. 填写 `01-openspec-proposal.md`<br>3. 执行状态转换 S0→S1 | S1 | `workflow/features/<feature-id>/01-openspec-proposal.md` |
| S1 规格撰写中 | OpenSpec 提案已有初稿 | 1. 检查是否为全新功能（vs 增量修改）<br>2. **若全新功能：** 触发 Gate 1 人类 Checkpoint，使用学习型 Checkpoint 六段结构呈现设计决策<br>3. **若增量修改：** 跳过人类 Checkpoint，直接准备进入 S2<br>4. 调用 `bash workflow/scripts/gate-check.sh <feature-id>`<br>5. Gate 1 通过后执行状态转换 S1→S2 | S2 | 人类签核记录（若全新功能） |
| S2 grill-me 挑战中 | 正在攻击提案寻找风险 | 1. 将 `01-openspec-proposal.md` 发送给挑战者<br>2. 若挑战者可达（dual-agent）：等待挑战者产出 `02-grill-me-report.md`<br>3. 若挑战者不可达（single-agent）：编排者手动填写 `02-grill-me-report.md`，标记 `source: manual-grill`<br>4. grill-me 报告完成后，调用 gate-check.sh 检查 Gate 2<br>5. Gate 2 通过后执行状态转换 S2→S3 | S3 | `02-grill-me-report.md` |
| S3 规格修正中 | 根据 grill-me 修订规格 | 1. 逐条处理 grill-me 发现：答复 / 接受 / 升级<br>2. 修订 `01-openspec-proposal.md`<br>3. P0/P1 必须全部 resolved 或 explicitly accepted<br>4. 若 Agent 间存在分歧且规格模糊 → 返回 S3 修正规格<br>5. 修正完成后执行状态转换 S3→S4 | S4 | 修订后的 `01-openspec-proposal.md` |
| S4 任务映射中 | 构建任务-技能映射表 | 1. 编写 `03-task-skill-map.md`：每个任务必须有 owner、skill routes、likely files、tests、rollback note<br>2. 识别可并行执行的独立分支<br>3. **触发人类 Checkpoint 的条件：**<br>   - 任务需要两个 Agent 都不具备的领域专业知识<br>   - 任务涉及生产数据 / 计费 / 认证 / 部署凭证<br>4. 调用 gate-check.sh 检查 Gate 3<br>5. Gate 3 通过后执行状态转换 S4→S5 | S5 | `03-task-skill-map.md` |
| S5 实现中 | 按任务映射表编写代码 | 1. 按已批准的任务映射表逐任务实现<br>2. 更新 `04-implementation-plan.md` 记录实际变更<br>3. **触发人类 Checkpoint 的条件：** 任务耗时超过估算 2x<br>4. 所有任务完成后调用 gate-check.sh 检查 Gate 4<br>5. Gate 4 通过后执行状态转换 S5→S6 | S6 | 代码变更 + `04-implementation-plan.md` |
| S6 双审中 | 等待/执行代码审查 | 1. 将 diff + proposal + task map 发送给审查者<br>2. 若审查者可达（dual-agent）：等待双方审查报告<br>3. 若审查者不可达（single-agent）：执行换帽自审三轮<br>4. P0/P1 必须 fixed 或 explicitly deferred<br>5. 两份审查同时标记同一 P0 → 停止 + 人类签核<br>6. 调用 gate-check.sh 检查 Gate 5<br>7. Gate 5 通过后执行状态转换 S6→S7 | S7 | `reviews/claude-review.md` + `reviews/codex-review.md` |
| S7 验证中 | 确认变更符合验收标准 | 1. 运行测试或执行手动检查<br>2. 填写 `05-verification-log.md`<br>3. 记录所有通过/失败的验收标准<br>4. 记录残余风险<br>5. **触发人类 Checkpoint 的条件：** 验收标准验证失败<br>6. 调用 gate-check.sh 检查 Gate 6<br>7. Gate 6 通过后执行状态转换 S7→S8 | S8 | `05-verification-log.md` |
| S8 知识捕获中 | 沉淀决策和经验 | 1. 编写 `06-adr.md`（架构决策记录）<br>2. 编写 `07-task-retro.md`（任务回顾）<br>3. 确保决策不困在聊天中<br>4. 调用 gate-check.sh 检查 Gate 7<br>5. Gate 7 通过后执行状态转换 S8→S9 | S9 | `06-adr.md` + `07-task-retro.md` |
| S9 归档 | 功能完成，等待合并 | 1. 整理最终制品集<br>2. 生成 PR 摘要 / 发布说明 / 归档说明<br>3. 确认所有 artifact 连贯且可发现<br>4. 功能文件夹标记为完成 | 结束 | PR 摘要 / 归档说明 |

### 挑战者路由表

挑战者不拥有主干，但对制品质量负责。

| 编排者所在状态 | 编排者要求 | 挑战者动作 | 挑战者产出物 |
|---|---|---|---|
| S2 | grill-me（技术风险审查） | 1. 读取 `01-openspec-proposal.md`<br>2. 攻击提案：找边缘情况、安全漏洞、性能瓶颈、数据丢失、规格缺口、契约断裂<br>3. 对每个风险标注严重级别（P0/P1/P2/P3）<br>4. 不重新审视 Gate 1 的设计决策 | `02-grill-me-report.md` |
| S6 | code-review（代码审查） | 1. 读取 diff、proposal、task map<br>2. 对照规格检查代码变更<br>3. 检查契约断裂、缺失迁移步骤、隐藏状态/并发问题、认证/权限漏洞<br>4. 以发现列表产出，标注严重级别 | `reviews/<agent>-review.md` |
| S8 | architecture-review（架构审查） | 1. 读取 ADR、实现笔记、验证日志<br>2. 压力测试架构决策的长期影响<br>3. 检查是否有遗漏的 ADR | 审查意见（可附在 `06-adr.md` 的 Revisit Trigger 部分） |
| 任意状态 | verify（验证） | 1. 读取验证日志<br>2. 重新运行/检查验证步骤<br>3. 确认残余风险是否可接受 | 验证记录 |

### 单 Agent 模式路由表（编排者 == 挑战者）

当 mode == `single-agent` 时，编排者同时承担挑战者职责，标记如下：

| currentState | 动作 | 特殊标记 |
|---|---|---|
| S2 | 编排者手动填写 `02-grill-me-report.md`（技术风险自审） | `source: manual-grill`<br>`mode: single-agent` |
| S3 | 编排者自答 grill-me 发现 | `accepted_by: <orchestrator>` |
| S6 | 编排者执行换帽自审三轮（实现者→怀疑者→验证者），遵循 `workflow/fallback-matrix.md` 中的单 Agent 审查协议 | `review_mode: single-agent`<br>每项发现标记 `single-agent` |
| S7 | 编排者执行静态审查 + 手动检查计划 | `tests: manual-plan`<br>`mode: single-agent` |

### 人类路由表

以下场景调度器必须将控制权交给人类（不可自动路由）：

| 触发状态 | 触发条件 | 人类需要决定什么 | 输出格式 |
|---|---|---|---|
| S0 | 功能描述模糊，存在多种合理解读 | 定义要构建什么 | 学习型 Checkpoint 六段结构 |
| S1 | 全新功能（非增量修改） | 规模、视觉风格、技术栈、功能范围、用户角色 | 学习型 Checkpoint 六段结构 |
| S4 | 领域知识缺口 | 提供知识、改写任务或手动处理 | 学习型 Checkpoint 六段结构 |
| S4 | 涉及生产数据/计费/认证/部署凭证 | 权限批准 | 学习型 Checkpoint 六段结构 |
| S5 | 任务耗时超过估算 2x | 终止、缩减范围或接受成本 | 学习型 Checkpoint 六段结构 |
| S7 | 验收标准验证失败 | 豁免还是回退修复 | 学习型 Checkpoint 六段结构 |
| S6 | 两份审查同时标记同一 P0 | 解决审查死锁 | 学习型 Checkpoint 六段结构 |
| 任意 | feedbackLoop.retryCount >= maxRetries | 豁免门禁、修正规格、缩减范围或人工接管 | 学习型 Checkpoint 六段结构 |
| 任意 | 两个 Agent 均不可达 AND 人类不可达 | 触发逃生舱协议 | ADR + 最小可逆步骤 |

---

## 三、门禁检查（Gate Check）集成

### 每个状态转换前必须执行

调度器在每次尝试状态转换时，必须：

```
1. 确定当前对应的门禁（见下方映射表）

2. 运行确定性门禁检查：
   bash workflow/scripts/gate-check.sh <feature-id>
   （该脚本零 LLM 调用，纯文件系统 + JSON 结构检查）

3. 读取 gate-check 输出：
   ┌─ RESULT: PASS（退出码 0）
   │  → 允许状态转换
   │  → 更新 feature-state.json:
   │    - 对应 gate 的 status 设为 "passed"
   │    - gate.checkResults 记录通过时间和检查者
   │    - currentState 更新为下一状态
   │    - stateHistory 追加状态转换记录
   │    - feedbackLoop.retryCount 重置为 0
   │
   └─ RESULT: FAIL（退出码 1）
      → 读取缺失的产物列表（missingArtifacts）
      → 记录失败到 feedbackLoop：
        a. feedbackLoop.retryCount += 1
        b. feedbackLoop.lastFailure = 当前时间
        c. feedbackLoop.lastFailureReason = 失败原因摘要
        d. feedbackLoop.lastFailureGate = 当前门禁
        e. feedbackLoop.feedbackInjected = false（初始值）
      → IF retryCount >= maxRetries（默认 3）:
          → 停止自动重试
          → 触发人类 Checkpoint（学习型 Checkpoint 六段结构）
          → 同时检查 feedbackLoop.stalledSince 是否超过 48h
      → ELSE IF retryCount >= 1 AND feedbackInjected == false:
          → 分析失败原因
          → 修正缺失项（补充产物文件）
          → 设置 feedbackLoop.feedbackInjected = true
          → 设置 feedbackLoop.feedbackSummary = 修正内容摘要
          → 重新调用 gate-check.sh
      → ELSE（仍有重试额度且已注入反馈）:
          → 尝试不同的修正策略
          → 重新调用 gate-check.sh
```

### 状态转换 → 门禁映射

| 状态转换 | 对应门禁 | gate-check.sh 检查内容（确定性，零 LLM） |
|---|---|---|
| S1 → S2 | Gate 1（规格就绪） | `01-openspec-proposal.md` 存在且 >500B，包含 Goals / Acceptance / Problem / Non-Goals 标记 |
| S3 → S4 | Gate 2（风险就绪） | `02-grill-me-report.md` 存在，包含 P0 / Risk / Severity 字段 |
| S4 → S5 | Gate 3（任务就绪） | `03-task-skill-map.md` 存在且 >300B，每个任务有 owner / skill / files |
| S5 → S6 | Gate 4（实现就绪） | `04-implementation-plan.md` 存在，代码变更可追溯到已批准任务，无范围漂移 |
| S6 → S7 | Gate 5（审查就绪） | `reviews/` 目录存在且包含至少 1 份 .md 审查报告 |
| S7 → S8 | Gate 6（已验证） | `05-verification-log.md` 存在且 >100B，验收标准已记录 |
| S8 → S9 | Gate 7（知识已捕获） | `06-adr.md` 存在且 >50B + `07-task-retro.md` 存在且 >50B |

### 状态 → 需要检查到的最大门禁

调度器调用 gate-check.sh 时，脚本会根据 `currentState` 自动确定需要检查的最高门禁。映射关系如下：

| currentState | 最高检查门禁 | 含义 |
|---|---|---|
| S0 | gate-1 | 刚启动，只检查 Gate 1 的产物是否有基本框架 |
| S1 | gate-1 | 正在写 OpenSpec，Gate 1 必须已通过 |
| S2 | gate-1 | grill-me 中，Gate 1 是前提 |
| S3 | gate-2 | 修正规格中，Gate 2 需检查 |
| S4 | gate-3 | 任务映射中，Gate 3 需检查 |
| S5 | gate-4 | 实现中，Gate 4 需检查 |
| S6 | gate-5 | 审查中，Gate 5 需检查 |
| S7 | gate-6 | 验证中，Gate 6 需检查 |
| S8 | gate-7 | 知识捕获中，Gate 7 需检查 |
| S9 | gate-7 | 已归档，所有门禁均应已通过 |

---

## 四、状态一致性校验

调度器在读取 `feature-state.json` 后，必须校验其与文件系统的一致性。

### 校验逻辑

```
对当前状态之前的每个门禁（即已完成的门禁），执行交叉验证：

FOR gate_id in [gate-1, gate-2, ..., gate-<currentState 索引>]:
  1. 读取该 gate 在 feature-state.json 中的 status
  2. 运行 gate-check.sh --min-gate <gate_id> 检查实际产物
  3. 比较：
     ┌─ JSON status == "passed" AND gate-check 返回 fail:
     │  ⚠️ 状态不一致！JSON 声称已通过但产物缺失。
     │  → 将状态标记为 inconsistent
     │  → 将 gate status 回退为 "failed"
     │  → 在 stateHistory 中记录回退事件
     │  → 通知编排者：需要重新完成此门禁
     │
     ├─ JSON status == "failed" AND gate-check 返回 pass:
     │  ℹ️ 产物已就绪但 JSON 未更新。
     │  → 将 gate status 更新为 "passed"
     │  → 记录更新事件
     │
     └─ JSON status == "waived":
        → 跳过检查（人类已豁免）

若任何状态不一致被检测到：
  → 调度器输出「状态不一致警告」
  → 列出不一致的门禁、JSON 状态、文件系统实际状态
  → 建议修正方案
  → 在一致性修复前，不路由新的实现任务
```

---

## 五、回归验证协议（另一个 Agent 回来时）

当 mode 从 `single-agent` 切换回 `dual-agent` 时触发。

### Step 1：识别需要交叉验证的制品

```
扫描 feature-state.json 的 gates[] 数组：
  → 找出所有 status == "passed" 或 "waived"
  → 筛选其中 findings[] 有 acceptedBy 为 orchestrator 自身的项
  → 或在 fallbackEvents 中记录了 reviewer_unreachable / challenger_unreachable
    且对应状态为 S2 或 S6
```

### Step 2：生成回归验证清单

```
对于每个需要交叉验证的门禁，确定审查重点：

Gate 2（grill-me）——若在 single-agent 下完成：
  → 由回归的 Agent 重新审查 grill-me 报告
  → 寻找之前编排者自审时可能遗漏的风险
  → 特别关注：架构层面的安全隐患、编排者的盲区假设

Gate 5（审查）——若在 single-agent 下完成：
  → 由回归的 Agent 重新审查完整 diff
  → 逐条检查标记为 single-agent 的发现是否成立
  → 使用回归 Agent 的标准审查模板补充审查

Gate 6（验证）——若在 single-agent 下完成：
  → 由回归的 Agent 重新运行验证步骤
  → 检查验收标准是否真正通过
  → 补充缺失的验证项
```

### Step 3：执行验证

```
1. 调度器编写交接文件 workflow/handoffs/<orchestrator>-to-<returning-agent>.md
   列出需要回归验证的制品清单和审查重点

2. 将交接文件交付给回归的 Agent

3. 回归的 Agent 完成后：
   → 更新对应 gate 的 findings（新增发现或确认已有发现）
   → 原 single-agent 标记保留（审计追溯），新增 dual-agent 确认记录
   → 在对应审查制品中追加「回归验证」章节

4. 调度器确认回归验证完成后：
   → 检查是否曾有 P0/P1 被单方面接受
   → 若有，重新评估这些风险是否需要以双审视角重新处置
```

### Step 4：升级模式

```
回归验证完成后，调度器更新 feature-state.json：

1. mode = "dual-agent"
2. 对应 Agent Status = "reachable"
3. 在 fallbackEvents 中找到对应的 unreachable 事件，设置 resolvedAt
4. stateHistory 追加模式切换记录：
   {
     "from": "<currentState>",
     "to": "<currentState>",      // 状态不变，模式变化
     "trigger": "agent-handoff",
     "actor": "dispatcher",
     "notes": "Agent 回归，single-agent → dual-agent"
   }
```

### 回归后不做什么

```
❌ 不撤回已完成的代码变更（除非回归审查发现 P0）
❌ 不重新开始整个工作流
❌ 不要求编排者重新解释所有决策
✅ 只审查上次 dual-agent 验证点之后产生的 delta
```

---

## 六、新功能创建流程

当无活跃功能，且人类请求启动新功能时，调度器执行：

```
1. 与人类确认：
   - 功能名称（人类可读）
   - 功能简要描述
   - 由谁编排（若人未指定，当前 Agent 自动成为编排者）

2. 生成 featureId：
   - kebab-case，小写字母数字 + 连字符
   - 至少 3 字符，最长 64 字符
   - 例如：'ai-werewolf', 'dispatcher-v2', 'gate-layer-upgrade'

3. 创建功能目录：
   mkdir -p workflow/features/<featureId>/
   mkdir -p workflow/features/<featureId>/reviews/

4. 检测另一方 Agent 可达性：
   - 尝试 MCP 或 CLI 调用
   - 若可达 → mode = "dual-agent", challenger = 另一方身份
   - 若不可达 → mode = "single-agent", challenger = "manual"

5. 创建 workflow/features/<featureId>/feature-state.json：

   参考 workflow/feature-state.schema.json 的完整结构，初始值：

   {
     "$schema": "../../feature-state.schema.json",
     "featureId": "<featureId>",
     "humanReadableName": "<人类可读名称>",
     "currentState": "S0",
     "orchestrator": "<当前 Agent 身份: codex | claude>",
     "challenger": "<另一方 Agent 身份，若未知则 manual>",
     "mode": "<dual-agent | single-agent>",
     "codexStatus": "<reachable | unreachable | unknown>",
     "claudeStatus": "<reachable | unreachable | unknown>",
     "mcpStatus": "<up | down | unknown>",
     "createdAt": "<ISO 8601 时间戳>",
     "updatedAt": "<ISO 8601 时间戳>",
     "gates": [
       { "gateId": "gate-1", "label": "规格就绪", "status": "pending",
         "requiredArtifacts": [
           { "path": "01-openspec-proposal.md", "type": "file", "minSizeBytes": 500,
             "description": "OpenSpec 提案——功能的目标、非目标、验收标准",
             "requiredFields": ["Goals", "Non-Goals", "Acceptance", "Problem"] }
         ]
       },
       { "gateId": "gate-2", "label": "风险就绪", "status": "pending",
         "requiredArtifacts": [
           { "path": "02-grill-me-report.md", "type": "file", "minSizeBytes": 300,
             "description": "grill-me 技术风险审查报告",
             "requiredFields": ["P0", "P1", "Risk", "Severity"] }
         ]
       },
       { "gateId": "gate-3", "label": "任务就绪", "status": "pending",
         "requiredArtifacts": [
           { "path": "03-task-skill-map.md", "type": "file", "minSizeBytes": 300,
             "description": "任务-技能映射表" }
         ]
       },
       { "gateId": "gate-4", "label": "实现就绪", "status": "pending",
         "requiredArtifacts": [
           { "path": "04-implementation-plan.md", "type": "file", "minSizeBytes": 100,
             "description": "实现计划和实际变更记录" }
         ]
       },
       { "gateId": "gate-5", "label": "审查就绪", "status": "pending",
         "requiredArtifacts": [
           { "path": "reviews/", "type": "directory", "minSizeBytes": 1,
             "description": "审查报告目录——至少含 1 份 .md 审查报告" }
         ]
       },
       { "gateId": "gate-6", "label": "已验证", "status": "pending",
         "requiredArtifacts": [
           { "path": "05-verification-log.md", "type": "file", "minSizeBytes": 100,
             "description": "验证日志——测试和手动检查记录" }
         ]
       },
       { "gateId": "gate-7", "label": "知识已捕获", "status": "pending",
         "requiredArtifacts": [
           { "path": "06-adr.md", "type": "file", "minSizeBytes": 50,
             "description": "架构决策记录" },
           { "path": "07-task-retro.md", "type": "file", "minSizeBytes": 50,
             "description": "任务回顾——经验教训" }
         ]
       }
     ],
     "stateHistory": [
       {
         "from": null,
         "to": "S0",
         "timestamp": "<ISO 8601>",
         "trigger": "auto-advance",
         "actor": "dispatcher",
         "notes": "功能初始化"
       }
     ],
     "feedbackLoop": {
       "retryCount": 0,
       "maxRetries": 3,
       "feedbackInjected": false
     },
     "fallbackEvents": [],
     "humanDecisions": [],
     "branchTasks": [],
     "metadata": {}
   }

6. 确认创建完成后：
   → 输出「功能 <featureId> 已创建，当前状态 S0」
   → 路由到编排者的 S0 动作：创建 01-openspec-proposal.md
   → 执行状态转换 S0 → S1
```

---

## 七、主会话退化协议

当调度器加载后，主 Agent 会话不再是「自主 Agent」，而是「受限执行器」。

### 编排者会话 = 确定性执行器

```
决策权限（允许做的事）：
  ✅ 填写当前状态对应的产物文件（OpenSpec、任务映射表、验证日志等）
  ✅ 调用 workflow/scripts/gate-check.sh 验证当前门禁
  ✅ 读取 workflow/features/<feature-id>/feature-state.json 确认下一步
  ✅ 读取 workflow/state-machine.md 确认合法状态转换
  ✅ 读取 workflow/fallback-matrix.md 处理降级场景
  ✅ 在触发条件满足时，以学习型 Checkpoint 六段结构呈现给人类
  ✅ 读取和写入 workflow/handoffs/ 中的交接文件
  ✅ 在 feature-state.json 中更新 gates[].checkResults 和 stateHistory

禁止行为（绝不执行）：
  ❌ 跳过任何门禁直接进入后续状态
  ❌ 在 gate-check.sh 未返回 pass 时修改 currentState
  ❌ 在 Gate 1 未通过时开始实现
  ❌ 在 Gate 2 未通过时开始实现
  ❌ 将无关重构混入实现任务（违反 Gate 4）
  ❌ 在单 Agent 模式下假装双 Agent 审查已完成
  ❌ 修改 feature-state.json 的 orchestrator 字段（它在 S0 设定后不可变）
  ❌ 基于「上次会话做了什么」的模型记忆做决策（必须读文件）
```

### 挑战者会话 = 验证器

```
决策权限（允许做的事）：
  ✅ 读取 workflow/features/<feature-id>/01-openspec-proposal.md
  ✅ 读取当前代码 diff 和任务映射表
  ✅ 执行 grill-me 或代码审查
  ✅ 将发现写入对应的审查制品（02-grill-me-report.md 或 reviews/*.md）
  ✅ 建议编排者修正问题
  ✅ 在编排者不可达时，根据 workflow/fallback-matrix.md 的
     Orchestrator Unreachable Protocol 执行有限接管

禁止行为（绝不执行）：
  ❌ 修改 OpenSpec 提案（除非编排者明确请求）
  ❌ 直接提交代码变更（除非编排者不可达且 fallback 协议明确授权）
  ❌ 批准无法追溯到已批准任务的代码
  ❌ 超出挑战者职责范围：挑战者是 critique，不是重建
```

---

## 八、反馈循环（Feedback Loop）协议

当 gate-check 失败且需要重试时，调度器管理重试策略：

```
1. 读取 feature-state.json 中的 feedbackLoop 当前状态

2. IF retryCount == 0:
   → 这是首次失败
   → 读取 gate-check 的 missingArtifacts 和 schemaErrors
   → 将缺失信息传递给编排者
   → 编排者修正问题后，重新调用 gate-check.sh

3. IF retryCount >= 1 AND retryCount < maxRetries（默认 3）:
   → 重复失败，进入分析模式

   IF feedbackInjected == false:
     → 上次没有注入反馈就重试了
     → 分析失败根因：
       - 产物文件缺失？→ 补充文件
       - 产物内容不满足 requiredFields？→ 补充章节
       - JSON schema 违规？→ 修正结构
     → 将修正注入制品
     → 设置 feedbackLoop.feedbackInjected = true
     → 设置 feedbackLoop.feedbackSummary = 修正内容摘要
     → 设置 feedbackLoop.feedbackSource = "gate-check"
     → 重新调用 gate-check.sh

   IF feedbackInjected == true:
     → 上次注入的修正无效，需要不同的策略
     → 分析为什么上一轮修正没有解决失败：
       - 修正方向错误？→ 重新理解失败原因
       - 规格本身的矛盾？→ 可能需要修改 proposal 而非产物格式
       - gate-check 的 requiredFields 不合理？→ 人类介入
     → 尝试不同的修正策略
     → 重试

4. IF retryCount >= maxRetries:
   → 停止自动重试
   → 触发人类 Checkpoint，使用学习型 Checkpoint 六段结构：
     - 📋 背景：哪个门禁、失败几次、每次失败的具体原因
     - 🔍 分析：已尝试的修正策略及其效果、为什么屡次失败
     - 📚 经验课堂：此类反复失败的常见根因（规格模糊、环境问题、能力缺口等）
     - 🎯 选项：
       A. 修正规格（降低门槛/调整 requiredFields）
       B. 豁免此门禁（人类承担剩余风险）
       C. 缩减功能范围（去掉导致门禁反复失败的复杂需求）
       D. 人工接管（Human-in-the-loop 直接处理）
     - ⭐ 推荐：基于失败模式的最佳推荐
     - ✋ 你的决策：等待人类选择
   → 等待人类决策后继续

5. 停滞检测：
   IF feedbackLoop.stalledSince 存在 AND 距今超过 48h:
     → 触发「人类不可用」协议
     → 按照 workflow/fallback-matrix.md → Human Unavailable Protocol
     → 若另一 Agent 可达，由该 Agent 根据降级矩阵决定下一步
     → 若两 Agent 均不可达，执行逃生舱协议
```

---

## 九、调度器自检

调度器自身也需接受检查——防止它变成另一个「靠自觉遵守」的软约束。

### 每次输出前的自检清单

```
调度器必须在输出路由指令前确认以下四项：

□ 已重新读取 feature-state.json（而非依赖会话记忆）
  确认方式：读取文件的时间戳 > 本次会话启动时间

□ 已确认当前状态与 requiredArtifacts 文件系统状态一致
  确认方式：gate-check.sh 已在本会话中运行且返回 pass
  或调度器手动确认了每个 requiredArtifact 的文件存在性

□ 已确认自己的角色（orchestrator vs challenger）
  确认方式：对比 feature-state.json 的 orchestrator 字段
  与当前 Agent 身份

□ 已确认 mode（dual-agent vs single-agent）和另一方可达性
  确认方式：Step 4 的回归检测 / 可达性验证已完成

若以上任何一项无法确认：
  → 输出「调度器状态不确定」
  → 列出无法确认的具体项和原因
  → 要求运行 gate-check.sh 获取确定性的文件系统状态
  → 建议人类确认后再继续
```

### 调度器故障模式

| 故障情况 | 调度器行为 | 恢复方式 |
|---|---|---|
| `feature-state.json` 不存在 | 报告「功能状态文件缺失」，不路由任何任务 | 创建 feature-state.json（新功能流程）或人类介入 |
| `feature-state.json` 解析失败 | 报告「JSON 损坏」，不路由任何任务 | 人类手动修复 JSON 或从备份恢复 |
| `gate-check.sh` 不可用 | 手动检查每个 requiredArtifact 的文件存在性，记录为 `manual-check` | 修复脚本或继续以手动模式 |
| `state-machine.md` 不可读 | 报告「状态机定义缺失」，不路由任何状态转换 | 从本包重新复制 state-machine.md |
| 多个功能同时活跃 | 按 featureId 字典序逐个处理。每个功能独立输出路由指令 | — |
| 当前状态与文件系统严重不一致 | 停止所有路由，要求人类介入排序 | 人类确认真相源后继续 |

---

## 十、与 gate-check.sh 的协作

调度器与 `workflow/scripts/gate-check.sh` 是密不可分的配对组件。

| 场景 | 调度器行为 | gate-check.sh 行为 |
|---|---|---|
| 会话启动 | 调用 `bash workflow/scripts/gate-check.sh <feature-id>` | 读取 feature-state.json，检查当前状态所需的所有门禁产物 |
| 状态转换前 | 调用 `bash workflow/scripts/gate-check.sh <feature-id> --min-gate <target-gate>` | 仅检查到目标门禁，输出 pass/fail |
| gate-check 返回 pass | 执行状态转换，更新 feature-state.json | 退出码 0 |
| gate-check 返回 fail | 读取失败项列表，决定是修正还是触发人类 Checkpoint | 退出码 1，列出失败项 |
| 人类豁免某门禁后 | 将对应 gate status 设为 "waived"，重新调用 gate-check | 跳过 waived 的门禁，检查下一个 |
| JSON 状态与文件系统不一致时 | 调用 `bash workflow/scripts/gate-check.sh --artifacts-only` | 仅检查产物文件存在性，忽略 JSON 元数据 |
| Schema 结构存疑时 | 调用 `bash workflow/scripts/gate-check.sh --schema-only` | 仅校验 feature-state.json 的 JSON Schema 合规性 |
| 需要机器可解析输出时 | 调用 `bash workflow/scripts/gate-check.sh --json` | 输出 JSON 格式结果 |

### 调度器与 gate-check 的责任边界

```
gate-check.sh 负责：
  ✅ 确定性地检查产物文件存在性（文件在不在、大不大）
  ✅ 确定性地校验 JSON Schema 合规性（字段齐不齐、类型对不对）
  ✅ 确定性地检查 Markdown 制品的 requiredFields（关键章节有没有）
  ✅ 输出 pass/fail 的可机器解析结果

调度器负责：
  ✅ 在正确的时机调用 gate-check.sh
  ✅ 解读 gate-check 的结果并做出路由决策
  ✅ 管理反馈循环（重试、注入修正、触发人类 Checkpoint）
  ✅ 检测状态不一致（JSON 声称 passed 但产物缺失）
  ✅ 管理降级协议（当 gate-check 不可用时的手动替代方案）

两者互不越界：
  ❌ gate-check.sh 不做路由决策
  ❌ 调度器不做产物检查（那是 gate-check.sh 的事）
  ❌ gate-check.sh 不调用 LLM——纯确定性逻辑
  ❌ 调度器不以模型推理覆盖 gate-check 的确定性输出
```

---

## 十一、文件结构速查

```
workflow/
├── dispatcher.md                 ← 本文件（常驻层，调度器 Agent 指令）
├── feature-state.schema.json     ← feature-state.json 的 JSON Schema（原子规则层）
├── state-machine.md              ← 状态机定义（常驻层，S0-S9 转换规则）
├── fallback-matrix.md            ← 降级矩阵（按需层，所有降级场景的处理协议）
├── learning-checkpoints.md       ← 学习型 Checkpoint 框架（按需层，人类交互格式）
├── templates/
│   ├── 01-openspec-proposal.md   ← OpenSpec 提案模板
│   ├── 02-grill-me-report.md     ← grill-me 报告模板
│   ├── 03-task-skill-map.md      ← 任务-技能映射表模板
│   ├── 04-implementation-plan.md ← 实现计划模板
│   ├── 05-verification-log.md    ← 验证日志模板
│   ├── 06-adr.md                 ← 架构决策记录模板
│   └── 07-task-retro.md          ← 任务回顾模板
├── scripts/
│   └── gate-check.sh             ← 确定性门禁检查脚本（Layer 2 核心，零 LLM 调用）
├── features/
│   └── <feature-id>/
│       ├── feature-state.json    ← 该功能的唯一状态文件（真相源）
│       ├── 01-openspec-proposal.md
│       ├── 02-grill-me-report.md
│       ├── 03-task-skill-map.md
│       ├── 04-implementation-plan.md
│       ├── 05-verification-log.md
│       ├── 06-adr.md
│       ├── 07-task-retro.md
│       └── reviews/
│           ├── claude-review.md
│           └── codex-review.md
├── handoffs/
│   ├── claude-to-codex.md        ← Claude → Codex 交接文件
│   └── codex-to-claude.md        ← Codex → Claude 交接文件
├── skills/
│   ├── find-skill-router.md      ← 技能路由查找指南
│   └── professional-subtask-card.md ← 专业子任务卡片格式
├── eval/
│   ├── scoring-engine.md         ← 评分引擎
│   └── dashboard.html            ← 评估仪表板
└── experience/
    ├── pipeline.md               ← 经验管道
    ├── lessons/                  ← 经验教训存放目录
    ├── patterns/                 ← 模式识别存放目录
    └── instincts/                ← 本能反应存放目录
```
