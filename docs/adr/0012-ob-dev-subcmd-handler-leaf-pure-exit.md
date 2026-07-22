# ob dev subcommand handlers are leaf-pure (return-as-exit-code); cmd_dev retains sole exit ownership

`ob dev` 二级子命令（list/modify/refresh/reset/finish/status/build）的 porcelain 生命周期编排——precondition 再校验 → dry-run gate → execute（调 `devtool_*_run`）→ relay（调 `dev_relay_result`）→ emit（调 `dev_emit_*`）→ exit-code 映射——从 `cmd_dev` 抽成独立 subcommand handler 时，本 ADR 记录：**handler 是 leaf-pure——函数绝不 `exit`，return exit-code 契约值（0/1/2/3），由 `cmd_dev`（L1 exit seam）独占 `exit`**。这是 [ADR-0010](0010-ob-dev-dispatch-leaf-pure-exit.md)（锁定 *helper* leaf-pure）的接力：对象从 helper 升级到 handler。本 ADR 固化触发条件，避免未来 explorer 把 handler 的 `return` + `cmd_dev` 收口 exit（现为字面 case 映射，见 Consequences）当冗余而下沉 exit。

Status: accepted

## Considered Options

1. **handler own exit（direct-exit module）** —— 拒绝。handler 内部直接 `exit` 收口，`cmd_dev` dispatch 入口退化为一句调用，handler 与 `cmd_*` 同构更薄。代价真实：(a) 打破 ADR-0010 的"exit 只在 `cmd_dev`"这条 dev 表面不变量——exit 流从 1 个文件散到 handler 文件；(b) **testability 回吐**——`exit` 在 unit 测里终止测试进程、要 `trap`/子 shell 包裹，而 handler 化的头号驱动正是 testability（dispatch 胶水从"只能 orchestration 间接测"变"unit 直测"）；(c) `exit_contract` Y 规则要把新 basename 从 leaf-pure 重分类为 direct-exit，门禁配置漂移。而 own-exit 的收益（dispatch 入口少一个 `exit $?` token）是 trivial 的——ADR-0010 已论证此类 token 不值得换不变量。

2. **leaf-pure + return-as-exit-code，`cmd_dev` 字面 case 映射收口** —— 接受。编排逻辑全部收进 leaf-pure handler（deepening 价值）。**原设计 `cmd_dev exit $?` 透传 dispatcher 返回码；实施时撞到 exit_contract X 规则禁 dynamic exit（仅 require_path 例外）+ `set -e` 截断风险，改为字面 case 映射收口（见 Consequences）**。守不变量；需将新 basename 进 leaf-pure 字典 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 守 Y（cmd_dev 收口另受 X 约束，非"零门禁改动"）；与 ADR-0010 helper 模式一致；`return` 可直接断言（unit 友好，不必 trap exit）。

## Consequences

- subcommand handler 所在的 leaf-pure module 是 **leaf-pure module**：函数绝不 exit，return `0`（成功）/`1`（失败）/`2`（取消）/`3`（前置缺失），由 `cmd_dev` 据返回码用**字面 case 映射**收口（`case "$_rc" in 0) exit 0;; 1) exit 1;; 2) exit 2;; 3) exit 3;; *) exit 1;; esac`，配 `_rc=0; handler || _rc=$?` 防 set -e 中止）——**不用 `exit $?`**，因 exit_contract X 规则禁 dynamic exit（仅 require_path 例外）。`exit_contract` Y 规则覆盖 leaf-pure basename（X 规则覆盖 cmd_dev 收口字面 exit）。
- **exit 只在 `cmd_dev`（L1 exit seam）**这条 dev 表面不变量保持：所有 `lib/devtool_*.sh`（含新 subcommand handler）都不直接 exit。未来 explorer 看到 handler `return` 非 0 而 `cmd_dev` 再字面 case 收口 exit，**不应视为冗余**而把 exit 下沉进 handler——与 ADR-0010 对 helper 的警告同构，但 handler 体量更大、return 多个值，下沉诱惑更强，故单独立 ADR 固化。
- exit-code 契约的失败语义（哪个值、哪条 remedy line）仍是 `cmd_dev` 的职责——handler 只编排 + 诊断（stderr + 返回码），不决定 exit-code 契约的 remedy 文案。前置缺失（如 build 未 modified → exit 3 + remedy）归 `cmd_dev`，不归 handler。
- 本 ADR 与 ADR-0010 接力而非依赖"不言自明"：ADR-0010 锁两族 *helper*（relay/emit），本 ADR 锁一类 *handler*（subcommand）。对象升级，是新类型。
