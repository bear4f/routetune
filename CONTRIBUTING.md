# 参与贡献

感谢你愿意为 routetune 出一份力。这份文档说明怎么提问题、怎么提交改动。

## 提交 Issue

开新 Issue 前先搜一下 [已有 Issue](https://github.com/bear4f/routetune/issues?q=is%3Aissue)，避免重复。

- **Bug**：用 Bug 报告模板，务必给出复现步骤、期望行为、实际行为和运行环境。
  能复现的 bug 修得快，不能复现的 bug 会一直挂着。
- **新功能**：用功能建议模板，先说清楚你遇到的**问题**，再说你想要的方案。
- **安全漏洞**：不要开公开 Issue，走 [SECURITY.md](./SECURITY.md) 的私密上报流程。

## 提交 Pull Request

1. **先开 Issue 讨论**（除非是错别字、文档小修等显而易见的改动）。
   避免你写完几百行才发现方向不对。
2. Fork 并从 `main` 切出分支：

   ```bash
   git checkout -b feat/短横线描述
   ```

3. 写代码，**并补上测试**。改了行为就要有覆盖它的测试。
4. 本地跑通检查再推：lint、类型检查、测试全绿。
5. 提交 PR，填完 PR 模板，关联对应 Issue（`Closes #123`）。

### 分支命名

| 前缀 | 用途 |
| --- | --- |
| `feat/` | 新功能 |
| `fix/` | 缺陷修复 |
| `docs/` | 仅文档改动 |
| `refactor/` | 不改变行为的重构 |
| `test/` | 只动测试 |
| `chore/` | 构建、依赖、CI 等杂项 |

### 提交信息

采用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)：

```
<类型>(<可选范围>): <简短描述>

<可选正文：解释「为什么」，而不是「做了什么」——做了什么看 diff 就知道>

<可选脚注：Closes #123 / BREAKING CHANGE: ...>
```

示例：

```
fix(router): 修复空路径匹配时的越界访问

匹配器在 segments 为空时直接取 [0]，导致空路径请求 panic。
改为先判空并回落到根路由。

Closes #42
```

类型取值：`feat` `fix` `docs` `style` `refactor` `perf` `test` `build` `ci` `chore` `revert`。

### 代码审查

- PR 保持小而聚焦。一个 PR 只做一件事——混在一起的改动审不动，也不好回滚。
- CI 必须全绿才会被合并。
- 评审意见要么改，要么回复说明为什么不改，不要静默忽略。

## 开发环境

见 [README 的「开发」章节](./README.md#开发)。

## 行为准则

参与本项目即表示你同意遵守 [行为准则](./CODE_OF_CONDUCT.md)。
