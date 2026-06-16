# 反馈循环（Feedback Loop）

> 门禁失败不是死胡同，是有方向的信号。反馈循环将每一次失败转化为修正输入，
> 通过可控重试与分层升级，确保工作流在「自动化韧性」与「人类兜底」之间找到平衡。

## 一、概述

反馈循环是工作流中的**自适应纠错层**，横跨 `workflow/state-machine.md` 的 S1-S8 所有状态。
它的核心逻辑只有一句话：

```
gate-check 失败 → 分析根因 → 注入修正 → 回退到正确状态 → 重试
             ↓ (重试耗尽)
          升级至人类 Checkpoint
```

反馈循环不是独立状态——它是每个门禁转换时的**内嵌机制**。dispatcher 在每次状态转换前
调用 `gate-check.sh`，若脚本返回 `fail`，dispatcher 不会执行状态转换，而是将控制权交给
本文件定义的反馈循环协议。

### 关键设计原则

1. **快速失败，智能重试。** 不要盲目重试同一件事——每次重试必须注入新的修正。
2. **分支隔离。** 一个分支的门禁失败不阻塞其他独立分支的进度。
3. **闭合学习弧。** Retro（S8）中沉淀的教训必须回流到 OpenSpec 撰写（S1），形成跨功能的经验积累。
4. **确定性阈值。** 3 次自动重试后强制升级到人类——防止 Agent 陷入死循环。
5. **dispatcher 读取反馈状态，不做推理。** dispatcher 是路由决策者，但它只读取 `feedbackLoop` 字段的
   结构化数据，不做「我认为应该再试一次」的主观判断。

---

## 二、核心循环：失败 → 注入 → 回退 → 重试

### 2.1 循环触发点

反馈循环在以下时刻被 dispatcher 激活：

| 触发点 | 状态转换 | 对应门禁 | 说明 |
|---|---|---|---|
| S1→S2 被阻 | Gate 1 失败 | 规格就绪 | `01-openspec-proposal.md` 缺失或不满足 requiredFields |
| S3→S4 被阻 | Gate 2 失败 | 风险就绪 | `02-grill-me-report.md` 缺失或不包含 P0/Risk/Severity |
| S4→S5 被阻 | Gate 3 失败 | 任务就绪 | `03-task-skill-map.md` 缺失或任务缺少 owner/skill/files |
| S5→S6 被阻 | Gate 4 失败 | 实现就绪 | `04-implementation-plan.md` 缺失或存在范围漂移 |
| S6→S7 被阻 | Gate 5 失败 | 审查就绪 | `reviews/` 目录为空或无 .md 审查报告 |
| S7→S8 被阻 | Gate 6 失败 | 已验证 | `05-verification-log.md` 缺失或验收标准未记录 |
| S8→S9 被阻 | Gate 7 失败 | 知识已捕获 | `06-adr.md` 或 `07-task-retro.md` 缺失 |

### 2.2 标准循环流程

```
┌─────────────────────────────────────────────────────┐
│                  gate-check.sh                        │
│                      ↓                                │
│               ┌──────┴──────┐                        │
│               │   PASS?     │                        │
│               └──────┬──────┘                        │
│                  Yes  │  No                          │
│                  ↓     ↓                              │
│           状态转换   读取 failureReason               │
│           retry=0     + missingArtifacts              │
│                       + schemaErrors                  │
│                       ↓                               │
│               ┌──────────────────┐                   │
│               │ retryCount < 3?  │                   │
│               └────┬────────┬────┘                   │
│                 Yes│        │No                      │
│                   ↓         ↓                         │
│           反馈注入协议   升级至人类 Checkpoint          │
│           (见 2.3)      (见第四章)                    │
│                   ↓                                   │
│           retryCount += 1                             │
│           回退到正确起始状态                          │
│           重新调用 gate-check.sh                      │
└─────────────────────────────────────────────────────┘
```

### 2.3 反馈注入协议

**反馈注入是反馈循环的核心——没有注入的重试只是浪费重试额度。**

每次门禁失败后，编排者（或 dispatcher 指定的修复者）必须执行以下分析-修正流程：

#### Step 1：失败分类

```
读取 gate-check.sh 的失败输出，将失败归类为以下之一：

类别 A — 产物文件缺失
  表现：requiredArtifact 的文件在磁盘上不存在
  例：02-grill-me-report.md 未创建
  修正：创建缺失文件，按对应模板填写内容

类别 B — 产物内容不满足 requiredFields
  表现：文件存在但缺少关键章节（如 01-openspec-proposal.md 缺少 Goals 或 Acceptance）
  例：OpenSpec 有 Problem 但没有 Non-Goals
  修正：补充缺失章节，确保每个 requiredField 都有对应内容

类别 C — JSON Schema 违规
  表现：feature-state.json 的 gates[].status 与实际不符
  例：gate status 为 "passed" 但对应产物不存在（状态不一致）
  修正：根据文件系统实际状态修正 status

类别 D — 内容质量不足（minSizeBytes 不满足）
  表现：文件存在但内容过短（通常意味着模板空壳）
  例：05-verification-log.md 只有模板标题，未填写实际验证结果
  修正：填写实质性内容
```

#### Step 2：根因分析

在注入修正前，回答三个问题：

1. **这个失败是首次出现还是重复失败？**
   - 首次 → 通常是忘写了，直接补充即可
   - 重复 → 说明上一个修正策略无效，需要换方向

2. **失败的深层原因是什么？**
   - 规格模糊导致无法写出满足 requiredFields 的内容？
     → 可能需要先回到 S3 修订规格，而不是硬凑字段
   - 能力缺口（编排者不知道怎么写）？
     → 触发人类 Checkpoint（S4 领域知识缺口）
   - 环境问题（工具不可用、文件系统只读）？
     → 进入 fallback-matrix.md 对应降级协议

3. **上一次修正为什么没通过？**
   （仅在 retryCount >= 1 时回答）
   - 修正方向错误？
   - 修正不完整？
   - gate-check 的 requiredFields 定义不合理？
     → 可能需要人类豁免此门禁

#### Step 3：注入修正并记录

```
修正完成后，在 feature-state.json 的 feedbackLoop 中记录：

{
  "feedbackLoop": {
    "retryCount": <更新后的重试次数>,
    "maxRetries": 3,
    "feedbackInjected": true,
    "feedbackSummary": "<本次修正的具体内容——一句话说清楚修了什么>",
    "feedbackSource": "gate-check",
    "lastFailure": "<ISO 8601>",
    "lastFailureReason": "<gate-check.sh 的原始失败输出摘要>",
    "lastFailureGate": "<gate-1 ~ gate-7>",
    "stalledSince": "<首次失败的时间——仅在 retryCount >= 1 时保留>",
    "previousAttempts": [
      {
        "attempt": 1,
        "strategy": "<上一次的修正策略>",
        "reasonFailed": "<为什么上次修正没通过>",
        "timestamp": "<ISO 8601>"
      }
    ]
  }
}
```

#### Step 4：回退到正确状态

注入修正后，**状态必须回退到该门禁的正确起始状态**，而非继续前进：

| 失败门禁 | 回退到 | 说明 |
|---|---|---|
| Gate 1 (S1→S2) | S1 | 回到 OpenSpec 撰写，补充缺失字段 |
| Gate 2 (S3→S4) | S3 | 回到规格修正，确保 grill-me 发现被完整记录 |
| Gate 3 (S4→S5) | S4 | 回到任务映射，补充任务定义 |
| Gate 4 (S5→S6) | S5 | 回到实现，补充实现计划或修正范围漂移 |
| Gate 5 (S6→S7) | S6 | 回到审查，补充审查报告 |
| Gate 6 (S7→S8) | S7 | 回到验证，补充验证日志 |
| Gate 7 (S8→S9) | S8 | 回到知识捕获，补充 ADR 或 retro |

回退操作写入 `feature-state.json` 的 `stateHistory`：

```json
{
  "from": "S5",
  "to": "S5",
  "timestamp": "<ISO 8601>",
  "trigger": "feedback-loop-rollback",
  "actor": "dispatcher",
  "notes": "Gate 4 失败，retryCount=2。修正：补充 04-implementation-plan.md 的 Spec Gaps Found 表。回退到 S5 重新实现。"
}
```

#### Step 5：重试

修正注入并回退后，编排者重新完成该状态的正常产出，然后调用 `gate-check.sh`。

---

## 三、重试上限与升级策略

### 3.1 三层重试模型

```
第一层：自动修正重试（retry 1-2）
  ├─ 编排者独立诊断失败原因
  ├─ 注入修正（补充产物、补充字段、修正 schema）
  ├─ 回退到正确状态
  └─ 重新尝试门禁通过

第二层：策略切换重试（retry 3）
  ├─ 前两次修正均失败 → 问题可能不在产物格式，而在规格本身
  ├─ 换一个根本不同的修正方向
  │   例：不是继续补字段，而是回到 S3 修订规格使 requiredFields 可被满足
  └─ 这是最后一次自动重试

第三层：人类升级（retry >= maxRetries，默认 3）
  ├─ 停止一切自动重试
  ├─ 以学习型 Checkpoint 六段结构呈现给人类
  └─ 等待人类决策（见 3.3）
```

### 3.2 重试计数规则

```
retryCount 的增减遵循以下规则：

✅ 每次 gate-check 失败 → retryCount += 1
✅ 状态成功转换（gate-check pass） → retryCount 重置为 0
✅ 分支合并时 → 该分支的 retryCount 独立，不累加到其他分支

❌ 不同门禁的 retryCount 不共享——每个门禁失败独立计数
   实现方式：feature-state.json 的 feedbackLoop 中记录 lastFailureGate，
   若本次失败的 gate 与 lastFailureGate 不同，retryCount 重置为 1
❌ 手动重试（人类要求"再试一次"）不消耗 retryCount，但需人类显式确认
```

### 3.3 人类升级格式

当 `retryCount >= maxRetries`（默认 3），dispatcher 停止自动路由，编排者必须以
`workflow/learning-checkpoints.md` 定义的**六段结构**呈现给人类：

```html
<div class="checkpoint-card">

  <!-- 1. 背景 -->
  <details open>
    <summary><strong>📋 背景——门禁反复失败</strong></summary>
    <p>功能 <code>&lt;feature-id&gt;</code> 在门禁
       <strong>&lt;gate-N&gt;（&lt;门禁标签&gt;）</strong> 已连续失败
       <strong>&lt;retryCount&gt; 次</strong>。</p>
    <ul>
      <li>当前状态：&lt;currentState&gt;（根据 state-machine.md）</li>
      <li>失败门禁：&lt;gate-N&gt;</li>
      <li>首次失败时间：&lt;stalledSince&gt;</li>
      <li>停滞时长：&lt;自 stalledSince 至今的时长&gt;</li>
      <li>若不做出决策：功能将在此门禁无限期阻塞</li>
    </ul>
  </details>

  <!-- 2. 分析 -->
  <details open>
    <summary><strong>🔍 分析——每次失败的具体原因与已尝试策略</strong></summary>
    <table>
      <tr><th>尝试</th><th>失败原因</th><th>修正策略</th><th>为什么无效</th></tr>
      <tr>
        <td>1</td>
        <td>&lt;gate-check 的缺失/错误输出&gt;</td>
        <td>&lt;第一次修正策略&gt;</td>
        <td>&lt;为何未通过&gt;</td>
      </tr>
      <tr>
        <td>2</td>
        <td>...</td>
        <td>...</td>
        <td>...</td>
      </tr>
      <tr>
        <td>3</td>
        <td>...</td>
        <td>...</td>
        <td>...</td>
      </tr>
    </table>
    <p><strong>深层假设检验：</strong>是否存在规格本身无法被满足的情况？
       是否有 requiredFields 在当前功能语境下不适用？</p>
  </details>

  <!-- 3. 经验课堂 -->
  <details open>
    <summary><strong>📚 经验课堂——此类反复失败的常见根因</strong></summary>
    <blockquote>
      <p><strong>有经验的开发者会怎么诊断这种反复失败？</strong></p>
      <ul>
        <li><strong>规格模糊：</strong>OpenSpec 的目标/验收标准写得过于宽泛，
            导致后续所有制品都无法精确满足。应该在 S3 修正规格本身，
            而不是在 S5/S6/S7 反复补字段。</li>
        <li><strong>能力缺口：</strong>编排者不具备该门禁所需的领域知识
            （如不会写 ADR、不懂验证方法），应触发 S4 领域知识 Checkpoint。</li>
        <li><strong>工具链断裂：</strong>gate-check.sh 的 requiredFields 与实际
            模板不匹配，或脚本本身有 bug。应先修复脚本。</li>
        <li><strong>模板空壳综合征：</strong>文件被创建但没有实际内容，
            需要编排者真正坐下来写——不是格式问题，是投入问题。</li>
      </ul>
    </blockquote>
  </details>

  <!-- 4. 选项 -->
  <h3>🎯 选项</h3>
  <table>
  <tr>
    <th></th>
    <th>A. 修正规格</th>
    <th>B. 豁免此门禁</th>
    <th>C. 缩减范围</th>
    <th>D. 人工接管</th>
  </tr>
  <tr>
    <td>简述</td>
    <td>回到 S3 修订 OpenSpec，使后续门禁可被满足</td>
    <td>人类确认「此门禁在当前功能中不适用」，直接标记 waived</td>
    <td>去掉导致门禁反复失败的复杂需求</td>
    <td>人类直接处理此门禁对应的制品</td>
  </tr>
  <tr>
    <td>✅ 优势</td>
    <td>根治问题，后续门禁更顺畅</td>
    <td>快速前进，不浪费时间</td>
    <td>降低复杂度，回归可行区间</td>
    <td>绕过 Agent 能力边界</td>
  </tr>
  <tr>
    <td>⚠️ 风险</td>
    <td>可能连锁影响已通过的门禁</td>
    <td>跳过的检查可能隐藏未来问题</td>
    <td>功能价值可能打折</td>
    <td>人类时间成本，且失去自动化优势</td>
  </tr>
  <tr>
    <td>💰 成本</td>
    <td>中等（重写 + 重新通过依赖门禁）</td>
    <td>低（一次决策）</td>
    <td>中低（删减规格）</td>
    <td>高（阻塞等待人类）</td>
  </tr>
  </table>

  <!-- 5. 推荐 -->
  <h3>⭐ 推荐</h3>
  <div style="background:#1a2e1a;border:1px solid #27ae60;border-radius:8px;padding:12px;">
    <p><strong>推荐方案：&lt;A/B/C/D&gt;</strong></p>
    <p><strong>推理链路：</strong>&lt;基于失败模式的推理&gt;</p>
    <p><strong>何时应推翻此推荐：</strong>&lt;边界条件&gt;</p>
  </div>

  <!-- 6. 决策 -->
  <h3>✋ 你的决策</h3>
  <p><em>[人类在此选择 A/B/C/D，或提出其他方案]</em></p>

</div>
```

### 3.4 升级后的状态变更

人类做出决策后，编排者（或 dispatcher）执行以下状态更新：

| 人类选择 | 状态变更 | feature-state.json 操作 |
|---|---|---|
| A. 修正规格 | 回退到 S3 | `currentState = "S3"`, `gates[1..N].status = "pending"`（重置被影响的后续门禁） |
| B. 豁免 | 该 gate status = `"waived"` | 在 `humanDecisions` 中记录豁免理由，`retryCount = 0`，继续状态转换 |
| C. 缩减范围 | 回退到 S3 或 S4 | 修订 `01-openspec-proposal.md` 的 Goals/Non-Goals，`retryCount = 0` |
| D. 人工接管 | `currentState` 不变 | 在 `metadata` 中设置 `humanTakeover: true`，等待人类完成该门禁制品 |

所有人类决策必须写入 `feature-state.json` 的 `humanDecisions` 数组：

```json
{
  "decisionId": "hd-<uuid>",
  "gateId": "gate-4",
  "trigger": "feedback-loop-max-retries",
  "context": {
    "retryCount": 3,
    "failureHistory": ["...","...","..."]
  },
  "options": ["amend-spec", "waive", "reduce-scope", "human-takeover"],
  "chosen": "amend-spec",
  "rationale": "人类提供的理由",
  "timestamp": "<ISO 8601>",
  "approvedBy": "<human identifier>"
}
```

---

## 四、分支级重试

### 4.1 分支隔离原则

根据 `workflow/state-machine.md`，S4 之后任务可能分支：

```text
S4 Task + Skill Map
  → Branch A: S5 → S6 → S7
  → Branch B: S5 → S6 → S7
  → Branch C: S5 → S6 → S7
  → Merge: S8 Knowledge Capture → S9 Archive / Merge
```

**分支级重试的核心规则：一个分支的门禁失败，不阻塞其他独立分支的进度。**

### 4.2 分支级 feedbackLoop 结构

每个分支在 `feature-state.json` 的 `branchTasks` 中维护独立的反馈循环状态：

```json
{
  "branchTasks": [
    {
      "branchId": "branch-A",
      "label": "前端搜索组件",
      "status": "in_progress",
      "currentState": "S5",
      "feedbackLoop": {
        "retryCount": 1,
        "maxRetries": 3,
        "lastFailureGate": "gate-4",
        "lastFailureReason": "04-implementation-plan.md 缺少前端组件的测试计划",
        "feedbackInjected": true,
        "feedbackSummary": "补充了 Jest + Testing Library 测试计划章节",
        "stalledSince": "2026-06-16T10:00:00Z"
      },
      "stateHistory": [
        { "from": "S5", "to": "S5", "trigger": "feedback-loop-rollback",
          "notes": "Gate 4 失败，retryCount=1。修正后重试。" }
      ]
    },
    {
      "branchId": "branch-B",
      "label": "后端 API 端点",
      "status": "completed",
      "currentState": "S7",
      "feedbackLoop": {
        "retryCount": 0,
        "maxRetries": 3
      }
    }
  ]
}
```

### 4.3 分支失败处理矩阵

| 场景 | 行为 | 对其他分支的影响 |
|---|---|---|
| Branch A 的 Gate 4 失败（retry 1-2） | Branch A 内部反馈注入 + 回退重试 | 无影响。Branch B/C 继续推进 |
| Branch A 的 Gate 4 达到 maxRetries | Branch A 暂停，升级给人类 | Branch B/C 可继续推进，但合并（S8）被阻塞——因为 S8 要求所有分支通过 Gate 4/5/6 |
| Branch A 的失败暴露了共享规格问题（如 OpenSpec 有矛盾） | 所有分支暂停，回到 S3 修正共享规格 | **影响所有分支。** 共享规格变更后，受影响的分支需重新评估是否需要部分回退 |
| Branch A 和 Branch B **同时**在同一门禁失败 | 触发合并诊断——检查是否为系统性原因（如 gate-check.sh bug） | 两个分支的 retryCount 独立累计。不互相消耗 |

### 4.4 分支合并时的反馈聚合

当所有分支完成 S7 准备进入 S8 时，dispatcher 执行**反馈聚合**：

```
1. 遍历 feature-state.json 的 branchTasks[].feedbackLoop
2. 收集所有分支的 retryCount 和 failurePattern
3. 聚合为功能级别的 feedbackLoop 摘要，写入根级 feedbackLoop.branchSummary
4. 该摘要是 S8 知识捕获（Retro）的关键输入——
   哪些门禁最容易失败、哪个分支最不稳定、是否存在跨分支的重复失败模式

示例聚合输出：
{
  "branchSummary": {
    "totalBranches": 3,
    "branchesWithRetries": 2,
    "totalRetriesAcrossBranches": 4,
    "mostFailedGate": "gate-4",
    "commonFailurePattern": "实现计划缺少测试计划章节——模板未强调此字段",
    "generatedAt": "<ISO 8601>"
  }
}
```

这一聚合直接喂入 S8 的 `07-task-retro.md`，成为「过程质量」维度的量化数据。

---

## 五、Retro → OpenSpec 学习反馈弧

### 5.1 闭合学习弧

工作流中最长的反馈弧不是门禁重试，而是**从 Retro（S8）回到 OpenSpec（S1）的跨功能学习**。

```
功能 A: S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8 → S9
                                                    ↓
                                          Retro 发现写入经验管道
                                                    ↓
功能 B: S1 ← 经验管道加载 ←─────────────────────────┘
         ↑
    在写 OpenSpec 时，编排者必须：
    1. 读取 workflow/experience/lessons/ 中与本功能相关的教训
    2. 在提案的「已知风险」或「经验参考」章节引用相关教训
    3. 若本次功能遇到新的模式，承诺写回经验管道
```

### 5.2 反馈弧的四个通道

从 Retro 到 OpenSpec 的反馈通过四个通道传递：

#### 通道 1：ADR（`06-adr.md`）

- **写入：** S8 中记录架构决策时，若决策是因门禁反复失败、反馈循环升级而触发的，必须在 ADR 的 Context 章节写明失败链路。
- **读取：** 后续功能的 S1 OpenSpec 撰写时，查阅相关 ADR，识别是否有可复用的决策或需避开的反模式。

#### 通道 2：Task Retro（`07-task-retro.md`）

- **写入：** S8 中记录每个任务的回顾时，必须包含「反馈循环统计」章节：
  - 该任务触发了几次门禁失败
  - 最常失败的门禁是哪个
  - 哪次修正最有效
  - 流程改进建议
- **读取：** 后续功能的 S4 任务映射时，参考历史 retro 中的「流程改进建议」优化映射策略。

#### 通道 3：经验管道（`workflow/experience/`）

- **写入路径：**
  - `workflow/experience/lessons/` —— 具体的教训（如「gate-4 最容易失败，因为模板不强调测试计划」）
  - `workflow/experience/patterns/` —— 跨功能的重复模式（如「前端分支的验证门禁失败率是后端的两倍」）
  - `workflow/experience/instincts/` —— 编排者的直觉（如「当 gate-check 连续两次报 minSizeBytes 不满足，优先怀疑模板空壳，而非内容不足」）

- **读取时机：**
  - 功能 S0 启动时，dispatcher 自动扫描 `workflow/experience/` 中与本功能关键词匹配的条目
  - 编排者在 S1 撰写 OpenSpec 时，提案底部的「经验参考」章节必须列出至少一条相关教训
  - 无相关教训时写「本次无直接相关经验记录」

#### 通道 4：反馈循环统计（`feedbackLoop.branchSummary`）

- **写入：** 分支合并时自动聚合（见 4.4）
- **读取：** 后续功能的 S4 任务映射时，dispatcher 检查历史功能的 branchSummary：
  - 若该类型功能历史上某门禁反复失败，在映射该门禁的依赖任务时附加 `risk: high-gate-failure`
  - 编排者可据此为该任务预留额外时间预算或更详细的完成标准

### 5.3 学习反馈弧的闭合检查

在 S8（知识捕获）完成后，dispatcher 执行一次闭合检查：

```
1. 检查 07-task-retro.md 是否包含「反馈循环统计」章节
2. 检查是否有新的经验写入 workflow/experience/ 的三个子目录
3. 检查 feedbackLoop.branchSummary 是否已生成
4. 若以上任一缺失：
   → 标记 Gate 7 中的对应 requiredArtifact 为不完整
   → 触发一次温和提醒（不算 failure，不消耗 retryCount）
   → 编排者补充后再通过 Gate 7
```

闭合检查确保**没有一个 Retro 是没有产出的**——每个功能的失败经验都必须沉淀为后续功能的成功杠杆。

---

## 六、与 dispatcher.md 的协作方式

### 6.1 责任边界

```
反馈循环（本文件）负责：
  ✅ 定义反馈注入的具体步骤（2.3）
  ✅ 定义重试上限和升级格式（第三章）
  ✅ 定义分支级重试的隔离规则（第四章）
  ✅ 定义 Retro→OpenSpec 学习弧（第五章）
  ✅ 定义 feature-state.json 的 feedbackLoop 字段 schema（第七章）

dispatcher（workflow/dispatcher.md）负责：
  ✅ 在 gate-check.sh 返回 fail 时，读取本文件决定重试还是升级
  ✅ 读取 feedbackLoop 字段的 retryCount 和 maxRetries
  ✅ 在 retryCount >= maxRetries 时停止自动路由，触发人类 Checkpoint
  ✅ 管理回退状态转换（stateHistory 写入）
  ✅ 分支合并时执行反馈聚合（4.4）
  ✅ S8 完成时执行闭合检查（5.3）

两者互不越界：
  ❌ dispatcher 不定义反馈注入的具体策略——那是本文件的事
  ❌ 反馈循环不决定路由——那是 dispatcher 的事
  ❌ 反馈循环不做产物检查——那是 gate-check.sh 的事
```

### 6.2 dispatcher 读取 feedbackLoop 的决策树

dispatcher 在每个状态转换前执行以下决策树（摘自 `workflow/dispatcher.md` 第八章，此处为协作视角的详细展开）：

```
dispatcher 调用 gate-check.sh
          ↓
    ┌─────┴─────┐
    │  PASS?    │
    └─────┬─────┘
      Yes │     No
          ↓       ↓
    状态转换   读取 feedbackLoop.retryCount
    retry=0          ↓
               ┌─────────────┐
               │ retryCount  │
               │ < maxRetries│
               │ (默认 < 3)  │
               └──┬──────┬───┘
               Yes│      │No
                  ↓      ↓
            读取          触发人类 Checkpoint
      feedbackInjected    （学习型六段结构）
            ↓             等待人类决策
      ┌─────┴─────┐       ↓
      │ Injected? │   人类选择后
      └─────┬─────┘   更新 state + retry=0
        Yes │  No      或 waive gate
           ↓    ↓
      策略切换  首次注入
      (见 3.1)  (见 2.3)
           ↓    ↓
      retryCount += 1
      回退到正确状态
      编排者修正后重新调用 gate-check.sh
```

### 6.3 协作的关键数据结构

dispatcher 在反馈循环中操作的核心字段（`feature-state.json` 中）：

| 字段路径 | 读写者 | 含义 |
|---|---|---|
| `feedbackLoop.retryCount` | dispatcher 写（+1），编排者只读 | 当前重试次数 |
| `feedbackLoop.maxRetries` | S0 初始化时写入，dispatcher 只读 | 重试上限（默认 3） |
| `feedbackLoop.feedbackInjected` | 编排者写（注入后置 true），dispatcher 只读 | 本次循环是否已注入修正 |
| `feedbackLoop.feedbackSummary` | 编排者写 | 修正内容摘要 |
| `feedbackLoop.lastFailure` | dispatcher 写 | 最近一次失败时间 |
| `feedbackLoop.lastFailureReason` | dispatcher 写（从 gate-check 输出提取） | 失败原因 |
| `feedbackLoop.lastFailureGate` | dispatcher 写 | 失败门禁 ID |
| `feedbackLoop.stalledSince` | dispatcher 写（首次失败时设置，后续不变） | 停滞开始时间 |
| `feedbackLoop.previousAttempts[]` | 编排者写（每次重试后追加） | 历史尝试记录 |
| `branchTasks[].feedbackLoop` | dispatcher 管理 | 各分支独立的反馈循环状态 |

---

## 七、feature-state.json 中的 feedbackLoop 完整 Schema

```json
{
  "feedbackLoop": {
    "retryCount": 0,
    "maxRetries": 3,
    "feedbackInjected": false,
    "feedbackSummary": null,
    "feedbackSource": null,
    "lastFailure": null,
    "lastFailureReason": null,
    "lastFailureGate": null,
    "stalledSince": null,
    "previousAttempts": [],
    "branchSummary": null,
    "escalationHistory": []
  }
}
```

### 字段详解

| 字段 | 类型 | 必填 | 描述 |
|---|---|---|---|
| `retryCount` | integer | 是 | 当前门禁的连续失败重试次数。状态成功转换后重置为 0。若失败门禁变化（如从 gate-4 变为 gate-5），重置为 1 |
| `maxRetries` | integer | 是 | 重试上限。默认 3。可由人类通过 `humanDecisions` 调整（增加或减少） |
| `feedbackInjected` | boolean | 是 | 当前重试周期内是否已注入过修正。初始为 false。编排者注入修正后置 true。进入下一轮重试时 dispatcher 重置为 false |
| `feedbackSummary` | string \| null | 否 | 本次注入修正的一句话摘要。例："补充了 04-implementation-plan.md 中缺失的测试计划章节" |
| `feedbackSource` | string \| null | 否 | 修正来源。枚举值：`"gate-check"`（来自 gate-check.sh 输出）\| `"self-diagnosis"`（编排者自行诊断）\| `"human"`（人类指示） |
| `lastFailure` | string \| null | 否 | 最近一次 gate-check 失败的时间（ISO 8601） |
| `lastFailureReason` | string \| null | 否 | 最近一次失败的原因摘要（截取自 gate-check.sh 输出的前 200 字符） |
| `lastFailureGate` | string \| null | 否 | 最近一次失败的门禁。枚举：`"gate-1"` ~ `"gate-7"` |
| `stalledSince` | string \| null | 否 | 首次失败的时间（ISO 8601）。仅在 retryCount >= 1 时保留，用于计算停滞时长。状态成功转换后清除 |
| `previousAttempts` | array | 否 | 历史尝试记录。每项含 `attempt`（序号）、`strategy`（策略描述）、`reasonFailed`（为何未通过）、`timestamp` |
| `branchSummary` | object \| null | 否 | 分支合并时的反馈聚合（见 4.4）。仅在所有分支完成 S7 后被 dispatcher 写入 |
| `escalationHistory` | array | 否 | 人类升级历史。每项含 `gateId`、`retryCount`、`humanDecision`、`timestamp` |

### 分支级独立字段（`branchTasks[].feedbackLoop`）

```json
{
  "branchId": "branch-A",
  "feedbackLoop": {
    "retryCount": 0,
    "maxRetries": 3,
    "feedbackInjected": false,
    "feedbackSummary": null,
    "lastFailure": null,
    "lastFailureReason": null,
    "lastFailureGate": null,
    "stalledSince": null,
    "previousAttempts": []
  }
}
```

分支级 feedbackLoop 结构是根级 feedbackLoop 的**子集**，不含 `branchSummary` 和 `escalationHistory`（这些仅在功能级别维护）。

---

## 八、与 state-machine.md 的状态对照

| state-machine.md 状态 | 反馈循环的关键行为 | 涉及的门禁 |
|---|---|---|
| **S0 启动** | feedbackLoop 字段初始化（retryCount=0, maxRetries=3） | 无（尚未进入门禁检查） |
| **S1 规格撰写** | 若 Gate 1 失败（S1→S2），回退到 S1 补充缺失章节 | Gate 1 |
| **S2 风险审查** | 本状态无直接门禁。S2 是 grill-me 执行状态，其完成质量由 Gate 2 在 S3→S4 时检查 | —（门禁在 S3→S4 转换时检查） |
| **S3 规格修正** | Gate 2 失败（S3→S4）时，回退到 S3。若失败根因指向 OpenSpec 矛盾，可能需回退到 S1 | Gate 2 |
| **S4 任务映射** | Gate 3 失败（S4→S5）时回退到 S4。分支级 feedbackLoop 在此状态初始化（每个 branchTask 独立维护） | Gate 3 |
| **S5 实现** | Gate 4 失败（S5→S6）时回退到 S5。**最常见的失败点**——实现计划容易不完整或出现范围漂移 | Gate 4 |
| **S6 双审** | Gate 5 失败（S6→S7）时回退到 S6。若两份审查同时标记同一 P0，触发人类 Checkpoint（独立于重试上限） | Gate 5 |
| **S7 验证** | Gate 6 失败（S7→S8）时回退到 S7。若验收标准验证失败（非门禁格式），触发人类 Checkpoint | Gate 6 |
| **S8 知识捕获** | Gate 7 失败（S8→S9）时回退到 S8。闭合检查在此状态执行——若未沉淀经验，不得进入 S9 | Gate 7 |
| **S9 归档** | 所有门禁均应已通过。若在此状态发现门禁回退（状态不一致），属于异常场景，需人工介入 | — |

### 状态回退路径图

```
S1 ← Gate 1 失败 ───────────────────────────────┐
  ↕ （规格矛盾时可能从 S3 回退到 S1）              │
S2                                                │
  ↓                                                │
S3 ← Gate 2 失败 ─────────────────────────────────┤
  ↓                                                │
S4 ← Gate 3 失败 ─────────────────────────────────┤
  ├→ Branch A: S5 ← Gate 4 失败 ──────────────────┤
  │             ↓                                  │
  │            S6 ← Gate 5 失败 ───────────────────┤
  │             ↓                                  │
  │            S7 ← Gate 6 失败 ───────────────────┤
  │             ↓                                  │
  ├→ Branch B: (同上)                              │
  └→ Merge: S8 ← Gate 7 失败 ─────────────────────┘
              ↓
             S9

每个 ← 表示一次潜在的反馈循环回退。
虚线 ── 表示回退到更早的状态（当根因在更上游时）。
```

---

## 九、故障模式与恢复

### 9.1 反馈循环自身的故障

| 故障 | 表现 | 恢复方式 |
|---|---|---|
| **无限重试循环** | retryCount 持续累计但从未触发人类升级 | 检查 maxRetries 是否被意外设为极大值。dispatcher 自检：若 stalledSince > 48h 且 retryCount >= 3，强制触发人类 Checkpoint（无视 maxRetries 配置） |
| **无效注入** | 每次修正相同内容，不改变策略 | dispatcher 检测：若 previousAttempts 中连续两次 `strategy` 相同且均失败，拒绝第三次相同策略。编排者必须提出**不同的**修正方向 |
| **门禁 waive 滥用** | 人类连续豁免多个门禁 | dispatcher 检测：若 `humanDecisions` 中连续 >= 3 个 `waive` 决策，提醒人类注意累积风险。不强制阻止（最终决策权在人类） |
| **分支反馈循环死锁** | 两个分支互相阻塞（Branch A 需要 Branch B 的产物才能通过门禁） | 检查 03-task-skill-map.md 的依赖声明。若发现循环依赖，回退到 S4 修正任务映射。在 stateHistory 中记录死锁解除事件 |
| **feedbackLoop JSON 损坏** | 字段缺失或类型错误 | gate-check.sh 的 `--schema-only` 模式检测并报告。手动修复或从 feature-state.schema.json 重新生成默认值 |

### 9.2 停滞检测与逃生

dispatcher 在每次读取 `feedbackLoop` 时执行停滞检测：

```
IF feedbackLoop.stalledSince 存在 THEN:
  stalled_duration = now - stalledSince

  IF stalled_duration >= 48 小时:
    → 触发「停滞超时」警告
    → 若 retryCount >= maxRetries:
      → 已升级给人类。追加提醒（不改变升级状态）。
    → 若 retryCount < maxRetries:
      → 检查编排者是否仍在工作。
      → 若编排者无活动痕迹（feature-state.json 的 updatedAt 距今 > 24h）：
        → 另一个 Agent（若可达）接管停滞功能的状态诊断
        → 若两个 Agent 均不可达且人类也不可达：
          → 执行 workflow/fallback-matrix.md 的 Human Unavailable Protocol
          → 记录 ADR，执行最小可逆步骤

  IF stalled_duration >= 72 小时:
    → 强制标记为 `needs-human-escalation`
    → 尝试通过 MCP/CLI 联系人类
    → 若人类 24 小时内无响应且另一 Agent 可达：
      → 另一 Agent 执行有限接管（按 fallback-matrix.md 的 Orchestrator Unreachable Protocol）
```

### 9.3 恢复后的状态一致性

当反馈循环成功（门禁通过）后，dispatcher 必须确保：

1. `retryCount` 重置为 0
2. `feedbackInjected` 重置为 false
3. `previousAttempts` 归档到 `stateHistory`（不丢失审计信息）
4. `stalledSince` 清除
5. `lastFailure` / `lastFailureReason` / `lastFailureGate` 清除
6. 分支级的对应 feedbackLoop 同步更新

归档示例：

```json
{
  "stateHistory": [
    {
      "from": "S5",
      "to": "S6",
      "timestamp": "<ISO 8601>",
      "trigger": "gate-pass-after-retry",
      "actor": "dispatcher",
      "notes": "Gate 4 在 2 次重试后通过。反馈历史：[attempt1: 补充测试计划章节, attempt2: 修正 Spec Gaps Found 表]。总停滞时长：45 分钟。"
    }
  ]
}
```

---

## 十、快速参考卡

### 编排者检查清单（遇到门禁失败时）

```
□ 读取 gate-check.sh 的失败输出，确定缺失/不满足的具体项
□ 分类失败类型（A=缺失文件 / B=缺失字段 / C=Schema 违规 / D=内容不足）
□ 检查 retryCount：若是首次失败，直接补充；若是重复失败，检查上次策略为什么无效
□ 注入修正：补充文件/字段/内容，确保不同于上次尝试
□ 在 feedbackLoop 中记录 feedbackSummary 和 previousAttempts
□ 回退到正确状态（见 2.3 Step 4 的回退表）
□ 重新调用 gate-check.sh
□ 若 retryCount >= maxRetries：停止，以学习型 Checkpoint 六段结构呈现给人类
```

### dispatcher 检查清单（反馈循环相关）

```
□ 每次状态转换前调用 gate-check.sh
□ 若 fail：读取 feedbackLoop.retryCount，判断是否 < maxRetries
□ 若 < maxRetries：将控制权交给编排者（反馈注入协议），不自行修正
□ 若 >= maxRetries：停止路由，触发人类 Checkpoint（六段结构）
□ 若 pass：重置 feedbackLoop 的所有 transient 字段，记录 stateHistory
□ 分支合并时：执行反馈聚合（4.4），写入 branchSummary
□ S8 完成时：执行闭合检查（5.3），确保经验已写入 experience/
□ 定期停滞检测：若 stalledSince >= 48h 且无活动，触发超时警告
```

### 人类决策快捷索引

| 场景 | 人类看到 | 可用的快速决策 |
|---|---|---|
| 门禁 3 次失败 | 六段结构升级票据 | A/B/C/D 四选一 |
| 停滞 >= 48h | 超时警告 + 升级票据（若尚未升级） | 确认继续等待 / 强制推进 / 缩减范围 |
| 停滞 >= 72h | 强制 escalation | 人工接管或委托另一 Agent |
| 连续 >= 3 waive | 累积风险提醒 | 确认接受累积风险 / 要求部分门禁重新通过 |
