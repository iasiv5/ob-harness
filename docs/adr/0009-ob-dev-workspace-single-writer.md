# ob dev workspace 单 writer 假设与锁协议触发条件

ob dev 的 workspace writer（`modify`/`reset`/`finish`/integration harness 回滚）都操作 `<build_dir>/workspace/`。当前没有 workspace 级互斥——`recipe metadata cache` 有 flock（`devtool_search.sh` 的 `.<machine>.recipes.lock`），但 workspace 本身无锁。`reset` 的设计文档 §294 已把 workspace 锁协议（按 canonical effective workspace_path 定位 `<effective-workspace>/.ob-workspace.lock`，覆盖 modify/reset/integration-cleanup/finish 所有 writer，从首次 status 持锁到 postcondition）列为「未来恢复 `--remove-work`（递归源码删除）的门槛」。`finish` 落地时面临是否同步引入该锁的决策。本 ADR 记录：**刻意不在 finish 这一轮引入锁**，并把锁协议的触发条件固定下来，避免未来 explorer 把"无 workspace 锁"当成疏漏想"补"。

Status: accepted

## Considered Options

1. **finish 同步引入全家 workspace 锁** —— 拒绝（本轮）。锁必须所有 writer 参与才有意义（半吊子锁——只 finish 用、reset/modify 不用——防不住并发写，形同虚设），所以要么不做要么做全。做全 = 横切 modify/reset/finish/integration-cleanup 四个 writer + 改 `_devtool_env_exec`（所有 devtool 子命令的原语），把一个"加对称 deep module"的任务变成横切改造；破坏已通过 round-4 评审 + `ob_dev_integration_safety.sh` fault-inject 回归的稳定 module；并引入 reset 当前完全没有的故障类别（死锁、flock fd 泄漏、持锁期间 devtool hang 导致全部 writer 阻塞、锁超时语义）；并发回归测试难写、CI 易 flaky。

2. **刻意不引入，债务显式化** —— 接受。理由三层：(a) §294 把锁门槛绑定在 `--remove-work`（破坏性递归删源码），这不是随意捆绑——`--remove-work` 并发 = 真正的源码数据丢失（不可逆），而 reset/finish 都 source-preserving（归档 attic、不删源码），并发最坏情况 = workspace metadata corruption（可重建）；按"不可逆性"排序还债，不是拖延。(b) `ob dev cleanup/收尾语义`（ADR-0008）的 fail-safe（status 权威 recheck / cleanup-needed 前置 / status-list 失败不降级 / exit 77）防的是**串行内**的部分失败，与**并发安全**正交、不依赖锁；finish 复用这条通则即可覆盖主要风险。(c) 关注点分离 + 最小改动：finish 这一轮的闭环价值是"补完 modify→落回"，并发安全是正交 concern，应作为独立工作项，不塞进 finish 让单一交付横切四 module。

## Consequences

- modify/reset/finish/integration-cleanup 维持 **workspace 单 writer 假设**：ob dev 不保证同一 machine 上并发写 workspace 的互斥。典型场景（单开发者、单 machine、串行调 ob）下不触发；agent 若并行起多个 ob dev 命令则可能踩到 TOCTOU 窗口（status 读 → reset/finish 写之间无锁）。
- workspace 锁协议（§294 设计：canonical effective workspace_path 定位 `.ob-workspace.lock`，覆盖所有 writer，首次 status 到 postcondition 持锁）的**触发条件是 `--remove-work`**；在该命令落地前不引入锁。引入时应作为独立工作项 + 独立评审 + 并发回归。
- `finish` 的 `patch landing` 探测（devtool finish 前后快照 `landing_layer` 文件树 diff）依赖单 writer 假设——layer 目录在 finish 期间无并发 ob 写，探测才可靠。未来若引入并发，该探测需重新评估（改用 git status 或持锁内快照）。
- 若未来 agent 并发成为 ob dev 的真实使用模式（而非假设），锁优先级上调——届时本 ADR 的"低频"前提被推翻，应重开评审。
- 未来 explorer 看到 modify/reset/finish 均无 workspace 锁，**不应视为疏漏**：见本 ADR 与 reset-design §294。
