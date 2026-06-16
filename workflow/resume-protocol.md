# 续跑协议（Resume Protocol）

> **核心原则：文件系统是唯一的跨会话记忆。不看聊天历史，只看文件。**

本协议定义 Agent 如何在中断后恢复工作、如何检测另一个 Agent 的回归、以及单双 Agent 模式切换时的验证排队机制。它与 `workflow/fallback-matrix.md` 协同工作，覆盖降级矩阵中"Resume Protocol"（第 128–136 行）的完整细节。

---

## 一、设计原则

1. **零聊天依赖。** 恢复决策不读取任何聊天历史。一切从 `feature-state.json` 和制品文件推导。
2. **确定性优先。** 只要文件系统完整，恢复路径唯一确定。不存在"Agent 自行判断该做什么"的模糊空间。
3. **fail-closed。** 任何无法从文件系统确认的状态 = 停止，要求人类介入。
4. **互补而非替代。** 本协议是 `fallback-matrix.md` 的搭档——降级矩阵定义"出问题时的替代方案"，本协议定义"回归正常时的恢复步骤"。
5. **跨 Agent、跨会话。** 同一份协议适用于 Claude 和 Codex，无论谁先回来。

---

## 二、Agent 回归检测

### 2.1 核心问题

在单 Agent 模式下，编排者（或挑战者）无法知道另一个 Agent 何时恢复可用。不能依赖 MCP 心跳——MCP 可能本身就有故障。必须建立一套**纯文件系统的回归信号检测机制**。

### 2.2 信号来源（按确定性排序）

| 优先级 | 信号 | 位置 | 判定逻辑 |
|---|---|---|---|
| **P0（最高）** | 交接文件时间戳更新 | `workflow/handoffs/<from>-to-<to>.md` | 文件的 `mtime` 晚于上次读取记录的时间 |
| **P1** | fallbackEvents 中出现新条目并被标记为 `resolved` | `feature-state.json` → `fallbackEvents[]` | `resolvedAt` 字段存在且非空 |
| **P2** | gate-check.sh 输出变化 | `bash workflow/scripts/gate-check.sh <feature-id>` 的退出码或 JSON 输出 | 之前缺失的产物现在存在，或之前 fail 的门禁现在 pass |
| **P3** | 对应 Agent 的审查制品被写入/更新 | `workflow/features/<feature-id>/reviews/claude-review.md` 或 `codex-review.md` | 文件 `mtime` 晚于上次检查时间 |
| **P4（最低）** | 新功能文件夹出现 | `workflow/features/` 下出现新目录，且其中 `feature-state.json` 的 `orchestrator` 为另一方 | 仅当另一方为编排者时有效 |

### 2.3 检测流程（每次会话启动时执行）

```
输入：当前 feature-state.json 的状态

Step 1：判断是否需要做回归检测

  IF mode == "dual-agent":
    → 不做回归检测。只做可达性验证（见 2.4）。
    → 流程结束。

  IF mode == "single-agent":
    → 继续 Step 2。

Step 2：确定缺席方

  读取 codexStatus 和 claudeStatus：

  IF codexStatus == "unreachable" → 缺席方 = Codex
  IF claudeStatus == "unreachable" → 缺席方 = Claude
  IF 两者均为 "unreachable" → 缺席方 = 两者

  → 记录缺席方身份，用于后续信号匹配。

Step 3：扫描回归信号

  按 P0→P4 优先级扫描以下信号：

  P0 — 检查交接文件（缺席方 → 己方）的 mtime：
    文件：workflow/handoffs/<缺席方>-to-<己方>.md
    条件：文件存在 AND mtime > feature-state.json 中记录的 lastHandoffCheck
    判定：✅ 缺席方已回归并写入了交接文件

  P1 — 检查 fallbackEvents：
    条件：存在 type="agent_unreachable" 的 fallbackEvents 条目
          AND 该条目有 resolvedAt 字段且非空
          AND resolvedAt > 上次会话的 updatedAt
    判定：✅ 缺席方已被调度器标记为恢复

  P2 — 检查 gate-check 输出：
    运行：bash workflow/scripts/gate-check.sh <feature-id> --json
    条件：之前 fail 的门禁现在 pass
    判定：⚠️ 可能缺席方已回归并补齐了缺失产物（需交叉验证）

  P3 — 检查审查制品：
    目录：workflow/features/<feature-id>/reviews/
    条件：<缺席方>-review.md 存在 AND mtime > 上次检查时间
    判定：✅ 缺席方已回归并提交了审查

  P4 — 检查新功能文件夹（仅当缺席方可能是编排者）：
    条件：workflow/features/ 下有新目录
          AND 其 feature-state.json.orchestrator == 缺席方身份
    判定：⚠️ 缺席方已回归并创建了新功能（可能与本功能无关）

Step 4：确认回归

  IF 任意 P0/P1/P3 信号为真：
    → ✅ 缺席方确认回归
    → 执行「第三节：模式切换协议」
    → 流程结束。

  IF 仅有 P2/P4 信号为真：
    → ⚠️ 不确定。无法排除是己方或第三方操作的结果。
    → 尝试主动联系缺席方（MCP > CLI > 交接文件请求确认）。
    → 若响应正常 → ✅ 确认回归，执行第三节。
    → 若无响应 → 保持 single-agent，更新 lastHandoffCheck 时间戳。

  IF 所有信号为假：
    → 缺席方仍未回归。保持 single-agent 模式。
    → 更新 feature-state.json 的 lastHandoffCheck。
    → 继续当前降级协议。
```

### 2.4 双 Agent 模式下的可达性验证

```
IF mode == "dual-agent"：

  1. 从 feature-state.json 读取 challenger 字段
  2. 确定「另一方」身份（与 orchestrator 不同的一方）
  3. 尝试联系另一方：
     - 优先：MCP 健康检查（如 echo ping）
     - 次选：CLI 调用
     - 最后：检查交接文件时间戳是否在合理时间窗口内更新

  4. 判断结果：
     ┌─ 响应正常：
     │  → 保持 mode = "dual-agent"
     │  → 双方 Status = "reachable"
     │
     └─ 无响应 / 超时：
        → 触发降级事件（reviewer_unreachable 或 challenger_unreachable，
          具体取决于 currentState 是 S2 还是 S6）
        → 按 workflow/fallback-matrix.md 对应协议降级
        → 设置 mode = "single-agent"
        → 设置不可达方 Status = "unreachable"
        → 在 fallbackEvents 中追加事件
```

### 2.5 检测禁忌

```
❌ 不依赖 MCP 状态字段——MCP 可能已挂但 Agent 实际在线
❌ 不依赖网络心跳——心跳可能被防火墙拦截
❌ 不依赖 Chat UI 中的在线状态——那不是 Agent 的可达性
❌ 不依赖「上次跟它聊天是 5 分钟前」的会话记忆——必须读文件
✅ 只依赖文件系统写入（交接文件、审查制品、feature-state.json）
✅ MCP/CLI 调用仅作为确认手段，不作唯一判断依据
```

---

## 三、模式切换协议：single-agent → dual-agent

### 3.1 触发条件

以下任一事件触发 single-agent → dual-agent 切换：

1. **回归信号 P0/P1/P3 确认**（见 2.3 Step 4）
2. **MCP/CLI 主动联系成功**（缺席方响应健康检查）
3. **人类手动指令**（例如："Codex 回来了，切回双 Agent"）

### 3.2 切换流程

```
Step 1：锁定当前状态

  1. 读取 feature-state.json 的 currentState
  2. 运行 gate-check.sh --json 获取当前所有门禁的实际状态
  3. 将两者的快照保存为「切换前检查点」（见 3.3）

Step 2：生成回归验证清单

  扫描 feature-state.json 的 gates[] 数组和 fallbackEvents[]：

  FOR EACH gate IN gates[]:
    IF gate.status == "passed" AND gate.passedInMode == "single-agent":
      → 将其加入回归验证清单

  FOR EACH event IN fallbackEvents[]:
    IF event.type IN ["challenger_unreachable", "reviewer_unreachable"]
       AND event.resolvedAt 不存在：
      → 将对应门禁加入回归验证清单
      → 若 event.stateAtTrigger == "S2" → 对应 Gate 2
      → 若 event.stateAtTrigger == "S6" → 对应 Gate 5

Step 3：对回归验证清单中的每项，确定审查重点

  Gate 2（grill-me）——若在 single-agent 下完成：
    → 回归 Agent 重新审查 grill-me 报告
    → 重点：编排者自审的盲区——架构假设、安全模型、并发风险
    → 输出：补充审查发现，追加到 02-grill-me-report.md
    → 标记：新增发现标注 source: regression-review

  Gate 5（代码审查）——若在 single-agent 下完成：
    → 回归 Agent 对照规格重新审查完整 diff
    → 重点：逐条验证标记为 single-agent 的发现是否成立
    → 输出：补充审查章节，追加到 reviews/<agent>-review.md
    → 标记：新增发现标注 source: regression-review

  Gate 6（验证）——若在 single-agent 下完成：
    → 回归 Agent 重新运行验证步骤
    → 重点：检查验收标准是否真正通过（非自证）
    → 输出：补充验证记录，追加到 05-verification-log.md
    → 标记：新增记录标注 source: regression-review

Step 4：编写回归交接文件

  调度器（或当前在线的编排者）创建：
    workflow/handoffs/<orchestrator>-to-<regression-agent>.md

  内容：
    - 回归 Agent 身份
    - 需要审查的门禁清单及审查重点
    - 上次 dual-agent 验证点的时间戳
    - 此后的所有 single-agent 产物列表
    - single-agent 下发现的 P0/P1 风险（需独立复核）

Step 5：回归 Agent 执行验证

  回归 Agent 收到交接文件后：
    1. 读取回归验证清单
    2. 逐项执行验证
    3. 将发现写入对应制品，标注 source: regression-review
    4. 将结果写回交接文件或直接更新 feature-state.json 的 gates[].checkResults

Step 6：升级模式

  回归验证全部完成后，更新 feature-state.json：

  {
    "mode": "dual-agent",                         // 切换模式
    "codexStatus": "reachable",                   // 更新缺席方状态
    "claudeStatus": "reachable",                  // 更新缺席方状态
    "fallbackEvents": [                            // 标记降级事件已解决
      {
        "...": "...",
        "resolved": true,
        "resolvedAt": "<ISO 8601>",
        "resolvedBy": "regression-protocol"
      }
    ],
    "stateHistory": [                              // 记录模式切换
      {
        "from": "<currentState>",
        "to": "<currentState>",                   // 状态不变，模式变化
        "trigger": "agent-regression",
        "actor": "dispatcher",
        "timestamp": "<ISO 8601>",
        "notes": "缺席方回归，single-agent → dual-agent。回归验证清单已执行。"
      }
    ]
  }
```

### 3.3 切换前检查点

在模式切换前，调度器必须保存一份不可变的检查点快照，确保回退有据可查。

```
检查点快照内容（写入 workflow/features/<feature-id>/checkpoints/regression-<timestamp>.json）：

{
  "checkpointType": "pre-regression",
  "capturedAt": "<ISO 8601>",
  "featureState": {
    "currentState": "<S0-S9>",
    "mode": "single-agent",
    "orchestrator": "<codex|claude>",
    "codexStatus": "<...>",
    "claudeStatus": "<...>"
  },
  "gatesSnapshot": [
    // 每个门禁的 status + passedInMode + 最后通过时间
    { "gateId": "gate-2", "status": "passed", "passedInMode": "single-agent", ... }
  ],
  "fallbackEventsSnapshot": [
    // 所有 unresolved 降级事件的副本
    { "type": "challenger_unreachable", "stateAtTrigger": "S2", "timestamp": "..." }
  ],
  "artifactHashes": {
    // 关键制品文件的 SHA-256 哈希，用于事后比对是否被回归验证修改
    "01-openspec-proposal.md": "<sha256>",
    "02-grill-me-report.md": "<sha256>",
    "03-task-skill-map.md": "<sha256>",
    "05-verification-log.md": "<sha256>"
  }
}
```

### 3.4 切换后不做什么

```
❌ 不撤回已完成并通过门禁的代码变更（除非回归审查发现 P0）
❌ 不重新开始整个工作流（S0 重来）
❌ 不要求编排者重新解释所有设计决策
❌ 不重复已经 dual-agent 验证过的门禁检查
✅ 只审查上次 dual-agent 验证点之后产生的 delta
✅ 只复核 single-agent 模式下的制品（自审盲区）
✅ 若回归审查发现 P0 → 回到 S3 修正规格，而非全盘推翻
```

---

## 四、跨会话续跑的最小上下文加载清单

### 4.1 原则

新会话启动时，Agent 不应加载"上次我做到了哪里"的聊天记忆——那不可靠且不可复现。应从文件系统中构建一个**最小化但完整的上下文**。

### 4.2 必读文件清单（按加载顺序）

```
第一层（常驻层——必读，无论当前状态）：

  1. workflow/state-machine.md          ← S0-S9 状态定义和转换规则
  2. workflow/fallback-matrix.md        ← 所有降级场景的处理协议
  3. workflow/resume-protocol.md        ← 本文件——中断恢复和回归检测
  4. workflow/learning-checkpoints.md   ← 人类 Checkpoint 的输出格式

第二层（功能状态层——必读，功能级）：

  5. workflow/features/<feature-id>/feature-state.json  ← 唯一真相源
      提取字段：
        - currentState（确定当前阶段）
        - orchestrator（确定己方角色）
        - challenger（确定挑战者身份）
        - mode（dual-agent / single-agent）
        - codexStatus / claudeStatus（可达性）
        - mcpStatus（MCP 可用性）
        - gates[].status（每个门禁是否通过）
        - fallbackEvents[]（降级历史）
        - feedbackLoop（重试状态）

第三层（制品层——按需，根据 currentState 加载）：

  currentState == S1 → 读 01-openspec-proposal.md
  currentState == S2 → 读 01-openspec-proposal.md + 02-grill-me-report.md
  currentState == S3 → 读 01-openspec-proposal.md + 02-grill-me-report.md
  currentState == S4 → 读 01-openspec-proposal.md + 03-task-skill-map.md
  currentState == S5 → 读 01-openspec-proposal.md + 03-task-skill-map.md
                      + 04-implementation-plan.md
  currentState == S6 → 读 01-openspec-proposal.md + 03-task-skill-map.md
                      + reviews/claude-review.md + reviews/codex-review.md
  currentState == S7 → 读 01-openspec-proposal.md + 05-verification-log.md
  currentState == S8 → 读 06-adr.md + 07-task-retro.md
  currentState == S9 → 读全部归档制品

第四层（交接层——按需，若存在则必读）：

  7. workflow/handoffs/claude-to-codex.md    ← 若 mtime > 上次会话启动时间
  8. workflow/handoffs/codex-to-claude.md    ← 若 mtime > 上次会话启动时间
  9. workflow/features/<feature-id>/checkpoints/  ← 若存在，读最新检查点

第五层（调度层——按需，若存在则必读）：

  10. workflow/dispatcher.md                 ← 调度器指令（若己方需做路由）
```

### 4.3 不求加载的内容（刻意排除）

```
❌ 聊天历史（任何形式）
❌ 会话日志
❌ 非当前功能的 feature-state.json
❌ 已完成功能的归档制品（除非当前功能显式引用）
❌ README / CHANGELOG / FEEDBACK-ANALYSIS（除非涉及项目级决策）
✅ 以上内容绝不作为恢复决策的依据
```

### 4.4 加载后的确定性判断

Agent 完成上述加载后，必须能**独立回答以下问题**（答案必须从文件内容直接推导，不依赖记忆）：

| 问题 | 答案来源 |
|---|---|
| 我是谁（编排者还是挑战者）？ | `feature-state.json.orchestrator` 对比己方身份 |
| 当前在哪个阶段？ | `feature-state.json.currentState` |
| 是单 Agent 还是双 Agent？ | `feature-state.json.mode` |
| 对方可达吗？ | `feature-state.json.{codexStatus,claudeStatus}` + 回归信号检测（第二节） |
| 上次通过了哪些门禁？ | `feature-state.json.gates[].status` |
| 有未解决的降级事件吗？ | `feature-state.json.fallbackEvents[]`（无 `resolvedAt` 的条目） |
| 正在重试吗？ | `feature-state.json.feedbackLoop.retryCount > 0` |
| 下一步该做什么？ | 对照 `state-machine.md` 和 `currentState` 查找下一个状态转换动作 |
| 有没有需要我复核的 single-agent 产物？ | `gates[].passedInMode == "single-agent"` |
| 对方给我留了交接吗？ | `handoffs/` 下对应文件的 `mtime` |

---

## 五、中断恢复的确定性判断

### 5.1 中断类型识别

并非所有中断都相同。调度器需先识别中断类型，再决定恢复策略。

| 中断类型 | 特征 | 恢复策略 | 参照章节 |
|---|---|---|---|
| **短暂挂起** | `feature-state.json.updatedAt` 距今 < 2 小时<br>无新增 fallbackEvents | 直接续跑，从 currentState 继续 | 4.2 第三层 |
| **会话正常结束** | `updatedAt` 距今 > 2 小时<br>无 unresolved fallbackEvents | 重新加载上下文，从 currentState 继续 | 4.2 全部五层 |
| **单 Agent 降级中断** | `mode == "single-agent"`<br>存在 unresolved fallbackEvents | 先执行回归检测（第二节），<br>再根据检测结果决定恢复路径 | 第二节 + 第三节 |
| **门禁失败中断** | `feedbackLoop.retryCount > 0`<br>`feedbackLoop.feedbackInjected == false` | 分析上次失败原因，注入修正，重新调用 gate-check | fallback-matrix.md 反馈循环 |
| **人类 Checkpoint 中断** | `feature-state.json` 中 `humanDecisions[]` 最新条目<br>的 `decision` 字段为空 | 等待人类决策。不做任何自动路由 | 学习型 Checkpoint |
| **逃生舱中断** | `fallbackEvents[]` 中存在 `type: "escape_hatch"` 条目 | 读取 ADR，执行最小可逆步骤，标记 `needs-human-review` | fallback-matrix.md 逃生舱 |

### 5.2 确定性恢复决策树

```
START
  │
  ├─ feature-state.json 存在？
  │  ├─ 是 → 继续
  │  └─ 否 → 当前无活跃功能。询问人类是否启动新功能。
  │
  ├─ mode == "dual-agent"？
  │  ├─ 是 → 执行可达性验证（2.4）
  │  │       ├─ 对方可达 → 正常续跑
  │  │       └─ 对方不可达 → 触发降级（fallback-matrix.md）
  │  │
  │  └─ 否（mode == "single-agent"）→ 执行回归检测（第二节）
  │         ├─ 对方已回归 → 执行模式切换（第三节）
  │         │               → 排队待验证项（第六节）
  │         │               → 恢复正常续跑
  │         │
  │         └─ 对方仍未回归 → 保持 single-agent
  │                          → 检查 feedbackLoop 状态
  │                          → 从 currentState 继续
  │
  ├─ 存在 unresolved fallbackEvents？
  │  ├─ 是，且类型为 escape_hatch → 执行逃生舱协议
  │  ├─ 是，且类型为 human_checkpoint → 等待人类决策
  │  └─ 否 → 正常
  │
  ├─ feedbackLoop.retryCount >= maxRetries？
  │  ├─ 是 → 停止自动重试，触发人类 Checkpoint
  │  └─ 否 → 继续
  │
  └─ 确定 currentState，加载对应制品，继续工作流
```

### 5.3 中断恢复的禁止行为

```
❌ 不重新读取已通过的 previous-state 制品（除非回归验证需要）
❌ 不基于「上次做到一半」的感觉修改代码——必须从制品文件重新理解
❌ 不在未确认对方可达性的情况下假设双 Agent 模式
❌ 不在 single-agent 模式下假装对方已审查
❌ 不跳过回归检测直接续跑
❌ 不在无人类指令的情况下重新分配 orchestrator 角色
```

---

## 六、单 Agent → 双 Agent 切换时的待验证项自动排队

### 6.1 排队机制概述

当 mode 从 `single-agent` 切换为 `dual-agent` 时，回归 Agent 不能立刻开始所有验证——需要按优先级和依赖关系排队。本机制确保：

- **无遗漏**：所有 single-agent 下通过的制品都被审查
- **有优先级**：P0 安全/数据风险优先审查
- **不阻塞**：低优先级的验证不阻碍编排者继续后续状态

### 6.2 待验证项的发现与分类

```
扫描 feature-state.json：

FOR EACH gate IN gates[]:
  IF gate.status == "passed" AND gate.passedInMode == "single-agent":
    1. 提取 gate 的所有 findings（若有）
    2. 筛选 acceptedBy == <orchestrator> 的发现（自审自批）
    3. 按 severity 分类：

队列 A（阻塞级 — 回归 Agent 必须立刻审查）：
  - Gate 2：有 P0 风险被 orchestrator 单方面接受
  - Gate 5：有审查发现被标记为 single-agent 且 severity == P0
  - Gate 6：验收标准在 single-agent 下被手动标记通过
  → 这些必须阻塞编排者从 currentState 继续前进

队列 B（优先级 — 回归 Agent 应在下次状态转换前审查）：
  - Gate 2：所有 single-agent 下的 grill-me 发现
  - Gate 5：所有 single-agent 下的审查发现（P1 及以上）
  - Gate 6：验证日志中无自动化测试覆盖的手动检查项
  → 编排者可继续 currentState 的工作，但在进入下一状态前需要回归审查结果

队列 C（补充级 — 回归 Agent 在空闲时审查）：
  - Gate 2/5/6 中 P2/P3 级别的发现
  - 制品格式完整性检查
  - 文档与代码的一致性
  → 不阻塞编排者，可异步进行
```

### 6.3 排队数据结构

回归验证清单写入 `workflow/features/<feature-id>/regression-queue.json`：

```json
{
  "createdAt": "<ISO 8601>",
  "createdBy": "dispatcher",
  "triggerEvent": "agent-regression",
  "returningAgent": "codex",
  "queues": {
    "blocking": [
      {
        "id": "reg-001",
        "gate": "gate-2",
        "item": "grill-me P0 风险#3：用户令牌存储在客户端 localStorage",
        "acceptedBy": "claude",
        "acceptedInMode": "single-agent",
        "severity": "P0",
        "sourceFile": "02-grill-me-report.md",
        "status": "pending",
        "assignedTo": "codex"
      }
    ],
    "priority": [
      {
        "id": "reg-002",
        "gate": "gate-5",
        "item": "审查发现 single-agent #1：缺少输入清理（XSS）",
        "acceptedBy": "claude",
        "acceptedInMode": "single-agent",
        "severity": "P1",
        "sourceFile": "reviews/claude-review.md",
        "status": "pending",
        "assignedTo": "codex"
      }
    ],
    "supplementary": [
      {
        "id": "reg-003",
        "gate": "gate-6",
        "item": "验证日志中手动标记通过的验收标准 #7（文件上传大小限制）",
        "sourceFile": "05-verification-log.md",
        "status": "pending",
        "assignedTo": "codex"
      }
    ]
  },
  "progress": {
    "totalItems": 3,
    "completedItems": 0,
    "blockingResolved": false,
    "priorityResolved": false
  }
}
```

### 6.4 排队执行规则

```
规则 1（阻塞队列优先）：
  回归 Agent 必须优先完成 blocking 队列中的所有项目。
  在 blocking 队列清空前，编排者不得执行任何不可逆的状态转换。
  （编排者可继续 currentState 内的只读工作，如补充文档、分析等）

规则 2（优先队列时限）：
  priority 队列必须在编排者完成 currentState 动作前完成。
  若编排者已到达 currentState 的出口条件（如 S5 代码写完准备进 S6），
  但 priority 队列未清空 → 编排者必须等待回归审查完成。

规则 3（补充队列异步）：
  supplementary 队列不阻塞任何状态转换。
  回归 Agent 可在任意时间完成，结果在下次会话启动时被读取。

规则 4（超时逃生）：
  IF 回归 Agent 在完成 blocking 队列前变为不可达：
    → 保持 single-agent 模式
    → blocking 队列中的项目升级为「人类需确认的风险」
    → 触发人类 Checkpoint，列出未验证的 P0 项

规则 5（完成标记）：
  每完成一个队列项，回归 Agent 更新 regression-queue.json：
    - status: "completed"
    - completedAt: <ISO 8601>
    - findings: [回归审查发现的新问题]
    - verdict: "confirmed" | "revised" | "escalated"
```

### 6.5 队列生命周期

```
创建 → 阻塞队列执行 → 优先队列执行 → 补充队列执行 → 归档

1. 创建：模式切换时由调度器自动生成
2. 执行：回归 Agent 逐项审查
3. 清空：所有队列项 status == "completed"
4. 归档：regression-queue.json 移动到
         workflow/features/<feature-id>/checkpoints/regression-completed-<timestamp>.json
         同时在 feature-state.json 的 stateHistory 中记录完成事件
```

---

## 七、与 fallback-matrix.md 的配合

### 7.1 协作关系

```
fallback-matrix.md 定义：降级路径（正常→降级）
resume-protocol.md 定义：恢复路径（降级→正常）

两者在以下事件中交集：
  - Agent 不可达 → Agent 回归
  - MCP 不可用 → MCP 恢复
  - 门禁失败 → 门禁重试通过
  - 人类不可达 → 人类回归
```

### 7.2 具体配合场景

#### 场景 A：grill-me 期间挑战者不可达 → 挑战者回归

```
降级（fallback-matrix.md Scenario 1/3）：
  orchestrator 手动填写 02-grill-me-report.md
  标记 source: manual-grill, mode: single-agent
  记录 fallbackEvent: challenger_unreachable, state=S2

恢复（resume-protocol.md）：
  1. 检测回归信号（第二节）
  2. 执行模式切换（第三节）→ Gate 2 排队
  3. 回归 Agent 重新审查 grill-me 报告
  4. 重点：编排者自审可能遗漏的架构风险
  5. 追加发现到 02-grill-me-report.md，标注 source: regression-review
  6. 更新 fallbackEvents: resolvedAt = <now>
```

#### 场景 B：审查期间审查者不可达 → 审查者回归

```
降级（fallback-matrix.md Scenario 2/4）：
  orchestrator 执行换帽自审三轮
  标记 review_mode: single-agent
  记录 fallbackEvent: reviewer_unreachable, state=S6

恢复（resume-protocol.md）：
  1. 检测回归信号
  2. 执行模式切换 → Gate 5 排队
  3. 回归 Agent 重新审查完整 diff
  4. 重点：逐条验证 single-agent 发现，补充对方 Agent 标准审查模板
  5. 追加发现到 reviews/<agent>-review.md，标注 source: regression-review
  6. 若发现 P0 → 回到 S3 修正。若通过 → 更新 fallbackEvents
```

#### 场景 C：多个降级事件叠加

```
情况：challenger_unreachable (S2) + reviewer_unreachable (S6) 同时存在
原因：Agent 从 S2 到 S6 一直不可达

恢复（resume-protocol.md — 叠加处理）：
  1. 两个降级事件都检测到 resolved
  2. 排队时 Gate 2 和 Gate 5 都加入队列
  3. 执行顺序：Gate 2（grill-me 回归审查）→ Gate 5（代码审查回归）
  4. Gate 2 回归审查若发现新 P0，可能导致 Gate 5 的审查基础变化
  5. 因此 Gate 2 在 blocking 队列，Gate 5 在 priority 队列
  6. 两者都完成后，标记所有 unresolved fallbackEvents 为 resolved
```

#### 场景 D：人类不可达期间 Agent 回归

```
降级（fallback-matrix.md Human Unavailable Protocol）：
  编排者执行了逃生舱：ADR + 最小可逆步骤 + needs-human-review

恢复（resume-protocol.md）：
  1. 回归 Agent 检测到对方回归（信号 P1：fallbackEvents 新增条目）
  2. 但 human_unreachable 的 fallbackEvent 尚未 resolved
  3. 此时双 Agent 可协作，但不可越过人类做需要签核的决策
  4. 双 Agent 共同审查逃生舱期间做出的变更
  5. 联合编写人类回归时的简报（放到 feature-state.json.humanDecisions 中）
  6. 等待人类决策后再清理 fallbackEvents
```

### 7.3 fallback-matrix.md 的 Resume Protocol 章节（第 128–136 行）与本文件的关系

```
fallback-matrix.md 的 Resume Protocol（精简版）：
  → 定义「当不可达 Agent 回归时」的 6 个步骤骨架

resume-protocol.md（本文件）：
  → 将每一步扩展为完整的检测、判定、排队、执行、记录流程
  → 定义了回归信号的文件系统检测机制（fallback-matrix.md 未覆盖）
  → 定义了单→双切换的验证排队机制（fallback-matrix.md 未覆盖）
  → 定义了跨会话上下文加载清单（fallback-matrix.md 未覆盖）

两者关系：
  - fallback-matrix.md 的 Resume Protocol 是索引/摘要
  - resume-protocol.md 是完整实现
  - 任何 Resume Protocol 的执行必须参照本文件，而非仅依赖那 6 行摘要
```

---

## 八、调度器集成

### 8.1 调度器如何调用本协议

`workflow/dispatcher.md` 的 Step 4（检测「另一个 Agent 是否回来了」）和第五节（回归验证协议）是本协议的执行入口。调度器在每次会话启动时：

```
1. 读取 workflow/resume-protocol.md（本文件）
2. 执行第二节（Agent 回归检测）
3. 根据检测结果决定是否执行第三节（模式切换协议）
4. 执行第四节（跨会话续跑的最小上下文加载清单）
5. 执行第五节（中断恢复的确定性判断）
6. 若触发模式切换，执行第六节（待验证项自动排队）
```

### 8.2 调度器与本协议的责任边界

```
调度器（dispatcher.md）负责：
  ✅ 在正确的时机触发回归检测
  ✅ 调用 gate-check.sh 做确定性产物检查
  ✅ 更新 feature-state.json（状态、模式、fallbackEvents）
  ✅ 路由 Agent 到正确的下一步动作
  ✅ 管理反馈循环

本协议（resume-protocol.md）负责：
  ✅ 定义回归信号的文件系统检测方法
  ✅ 定义 mode 切换的完整流程
  ✅ 定义跨会话的最小上下文
  ✅ 定义中断类型和恢复策略
  ✅ 定义待验证项的自动排队规则

两者互不越界：
  ❌ 调度器不定义「如何检测」的细节（那是本协议的事）
  ❌ 本协议不定义「检测后路由给谁」的决策（那是调度器的事）
  ❌ 调度器不做中断恢复的上下文选择（那是本协议第四节的事）
  ❌ 本协议不操作 feature-state.json（那是调度器的专属职责）
```

---

## 九、常见中断场景与恢复速查

| 中断场景 | 中断时状态 | feature-state.json 特征 | 恢复动作 |
|---|---|---|---|
| 会话超时，S5 实现写到一半 | S5 | `mode: dual-agent`, `currentState: S5` | 重新读取 4.2 全部五层，加载 04-implementation-plan.md 确认进度，从下一个未完成任务继续 |
| 网络断开，S2 grill-me 等待挑战者 | S2 | `mode: dual-agent`, `currentState: S2`, `challenger: codex` | 执行可达性验证 → 若 Codex 不可达 → 触发降级 → 编排者手动 grill-me |
| 编排者离线，挑战者在线 | S6 | `mode: dual-agent`, `orchestrator: codex`, `currentState: S6` | 挑战者检查 fallback-matrix.md Orchestrator Unreachable Protocol：评估最后一个检查点，决定审查 delta 还是回退 |
| 两个 Agent 都离线 24h 后 Claude 先回来 | S5 | `mode: single-agent`, `claudeStatus: reachable`, `codexStatus: unreachable` | Claude 执行回归检测 → 未检测到 Codex 回归 → 从 S5 继续 single-agent |
| 两个 Agent 都离线 24h 后 Codex 先回来（Codex 是编排者） | S5 | `mode: single-agent`, `codexStatus: reachable`, `claudeStatus: unreachable` | Codex 执行回归检测 → 未检测到 Claude 回归 → 从 S5 继续 single-agent |
| S6 审查中 Claude 离线，Codex 做了换帽自审，然后 Claude 回归 | S6 | `mode: single-agent`, `fallbackEvents: [reviewer_unreachable]`, `claudeStatus: unreachable→reachable` | 检测 Claude 回归 → 执行模式切换 → Gate 5 排队 → Claude 重新审查 single-agent 发现 |
| 整个 S2–S6 都在 single-agent 下完成，Codex 直到 S7 才回归 | S7 | `mode: single-agent`, `fallbackEvents: [challenger_unreachable, reviewer_unreachable]` | 检测 Codex 回归 → 执行模式切换 → Gate 2 + Gate 5 + Gate 6 全部排队 → Codex 优先审查 blocking 队列（P0 风险） |

---

## 十、自检清单

每次会话启动时，Agent 在做出任何动作之前，必须完成以下自检：

```
□ 已读取 feature-state.json（而非依赖记忆）
□ 已执行 Agent 回归检测（第二节）
□ 已确定己方角色（编排者 vs 挑战者）
□ 已确定当前模式（dual-agent vs single-agent）
□ 已加载当前状态对应的制品文件（4.2 第三层）
□ 已检查 handoffs/ 下是否有未读的交接文件
□ 已检查 feedbackLoop 状态（是否在重试中）
□ 已检查是否存在未解决的人类 Checkpoint
□ 已确认所有前序门禁的产物文件确实存在（gate-check.sh）
□ 已确定下一步动作（对照 state-machine.md 的转换规则）

若以上任何一项无法确认：
  → 停止
  → 输出不能确认的具体项和原因
  → 要求运行 gate-check.sh --json 获取确定性状态
  → 建议人类确认后继续
```

---

## 文件结构

```
workflow/
├── resume-protocol.md              ← 本文件
├── fallback-matrix.md              ← 降级矩阵（与本文件互补）
├── state-machine.md                ← 状态机定义
├── dispatcher.md                   ← 调度器（调用本协议）
├── learning-checkpoints.md         ← 人类 Checkpoint 格式
├── features/
│   └── <feature-id>/
│       ├── feature-state.json      ← 唯一真相源
│       ├── regression-queue.json   ← 回归验证排队数据（第六节）
│       └── checkpoints/
│           ├── regression-<timestamp>.json  ← 模式切换前检查点（3.3）
│           └── regression-completed-<timestamp>.json ← 已完成队列归档（6.5）
```

---

> **本协议与 fallback-matrix.md 的「Resume Protocol」章节（第 128–136 行）一起构成完整的续跑体系。**
> **fallback-matrix.md 提供骨架；本文件提供血肉。**
> **所有恢复决策必须基于文件系统，而非聊天历史。**
