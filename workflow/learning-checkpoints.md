# 学习型 Checkpoint 框架

> 每个需要人类介入的门禁，都应是一次学习机会，而非仅仅是一个"stop sign"。

## 设计原则

1. **先教后问**——人类做决策前，先理解这个决策为什么重要
2. **给出选项，不给焦虑**——每条路都清楚标注利弊
3. **沉淀经验**——每次决策后，将学到的东西写回 ADR 或 retro
4. **可追溯**——每个决策都可追溯到哪个门禁、什么时候、为什么这样做

## 六段输出结构

每个学习型 Checkpoint 的输出必须按以下结构组织：

```html
<div class="checkpoint-card">

  <!-- 1. 背景 -->
  <details open>
    <summary><strong>📋 背景 (Context)</strong></summary>
    <p>现在发生了什么？为什么走到了这个决策点？</p>
    <ul>
      <li>当前工作流阶段</li>
      <li>关联的前序决策</li>
      <li>不做出决策的后果</li>
    </ul>
  </details>

  <!-- 2. 分析 -->
  <details open>
    <summary><strong>🔍 分析 (Analysis)</strong></summary>
    <p>Agent 已经考虑了哪些因素？</p>
    <ul>
      <li>技术约束</li>
      <li>竞品/业界参考</li>
      <li>已排除的方案及排除理由</li>
    </ul>
  </details>

  <!-- 3. 经验课堂 -->
  <details open>
    <summary><strong>📚 经验课堂 (Learning)</strong></summary>
    <blockquote>
      <p><strong>有经验的开发者会怎么想？</strong></p>
      <p>这里放：</p>
      <ul>
        <li>相关的设计原则/设计模式</li>
        <li>业界常见做法的 trade-off</li>
        <li>真实项目中的教训或案例</li>
        <li>"如果是我第一次做这个，我会希望有人告诉我..."</li>
      </ul>
    </blockquote>
  </details>

  <!-- 4. 选项 -->
  <h3>🎯 选项 (Options)</h3>
  <table>
  <tr>
    <th></th>
    <th>方案 A</th>
    <th>方案 B</th>
    <th>方案 C</th>
  </tr>
  <tr>
    <td>简述</td>
    <td></td><td></td><td></td>
  </tr>
  <tr>
    <td>✅ 优势</td>
    <td></td><td></td><td></td>
  </tr>
  <tr>
    <td>⚠️ 风险</td>
    <td></td><td></td><td></td>
  </tr>
  <tr>
    <td>💰 成本</td>
    <td></td><td></td><td></td>
  </tr>
  <tr>
    <td>适合谁</td>
    <td></td><td></td><td></td>
  </tr>
  </table>

  <!-- 5. 推荐 -->
  <h3>⭐ 推荐 (Recommendation)</h3>
  <div style="background:#1a2e1a;border:1px solid #27ae60;border-radius:8px;padding:12px;">
    <p><strong>推荐方案：X</strong></p>
    <p><strong>推理链路：</strong>...</p>
    <p><strong>何时应推翻此推荐：</strong>...</p>
  </div>

  <!-- 6. 决策 -->
  <h3>✋ 你的决策 (Decision)</h3>
  <p><em>[人类在此做出选择]</em></p>

</div>
```

## 七个门禁的学习锚点

每个门禁都有一个核心"学点"——人类在此应该带走的知识：

| 门禁 | 核心学点 | 人类学到什么 |
|---|---|---|
| Gate 1 | 设计决策 | 产品方向如何影响技术架构；视觉风格如何影响用户体验；为什么 v1 要剪裁范围 |
| Gate 2 | 风险认知 | 技术风险评估的框架；哪些风险值得现在解决、哪些可以接受；安全思维 |
| S4（领域知识） | 领域建模 | 如何将一个陌生领域的知识转化为代码结构 |
| S4（权限/凭证） | 安全边界 | 生产系统的权限模型；最小权限原则；凭证管理最佳实践 |
| S5（工作量爆炸） | 估算与调整 | 为什么估算会失效；如何识别 sunk cost；何时止损 |
| S7（验收失败） | 质量标准 | 验收标准的粒度；什么情况可以豁免、什么情况绝不能放松 |
| Gate 5（审查） | 代码品味 | 好的代码 vs 能用的代码；技术债务的识别与管理 |

## 使用示例

详见 `examples/ai-werewolf/` 中 Gate 1 的实际输出——
这是我们第一次在生产中使用学习型 Checkpoint 格式的完整记录。

## 常见问题

**Q: 经验课堂的内容从哪里来？**
A: Agent 的训练数据中包含大量设计原则、架构模式、真实案例。
关键是 Agent 要主动检索并呈现，而非被动等人类问。如果 Agent 不确定，
标注"以下基于一般原则，非特定于此领域"。

**Q: HTML 在终端里渲染不好怎么办？**
A: 学习型 Checkpoint 主要用于项目制品（.md 文件），
这些制品通常在浏览器/GitHub 中查看。CLI 中的即时摘要只需纯文本的
"推荐 + 选项编号"，人类如果感兴趣会打开文件看完整版。

**Q: 如何防止经验课堂变成废话？**
A: 两个约束：(1) 必须引用具体的设计原则或真实案例；
(2) 不超过 5 句话。没有具体引用就不写。
