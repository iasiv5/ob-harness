# ob dev dispatch helpers are leaf-pure; cmd_dev retains sole exit ownership

`ob dev` 的 dispatch/emit seam 深化（`dev_relay_result` + `dev_emit_*`）抽出了两族被 6 个子命令分支重复的 helper：failure-relay（stderr cat/rm + stage/phase/rc 诊断）和 result-encoder（porcelain JSON 编码 + 原子发布）。本 ADR 记录：**这些 helper 是 leaf-pure module——函数绝不 exit，返回码，由 `cmd_dev`（L1 exit seam）独占 `exit`**——并把触发条件固定下来，避免未来 explorer 把它们"修"成 own-exit（direct-exit module）。

Status: accepted

## Considered Options

1. **helper own exit（direct-exit module）** —— 拒绝。`dev_fail <subcmd> <stage> <phase>` 内部 `exit 1` 让 `cmd_dev` 分支更"干净"（无 `|| exit 1` token），但代价真实：(a) 第一次在 dev 表面打破"exit 只在 `cmd_dev` L1"这条全表面不变量——现有 `devtool_modify_run`/`reset_run`/`finish_run` 全是 leaf-pure 返回 rc、调用者 exit；(b) `exit_contract` Y 规则要把新 basename 从 leaf-pure 重分类为 direct-exit，门禁配置漂移；(c) exit 流散到更多文件，"理解 exit 流只读 cmd_dev"的心智模型破裂。而被复制的复杂度是**映射逻辑**（stage/phase/rc → 哪条 message），不是那个 `exit` 关键字——`cmd_dev` 里剩下的 `|| exit 1` 只是 trivial token。

2. **混合：failure-relay own exit，result-encoder leaf-pure** —— 拒绝。无原则折中，两族 helper 同属"调完 `*_run` 之后的标准动作"，要么都 leaf-pure 要么都 own-exit，不能半个半。

3. **全部 leaf-pure，返回码，`cmd_dev` 独占 exit** —— 接受。映射逻辑全部收进 leaf-pure helper（deepening 的价值拿到），`cmd_dev` 每分支保留 `dev_relay_result ... || exit 1` 一个 token。守不变量、零门禁改动、与现有 `devtool_*_run` 一致。

## Consequences

- `lib/devtool_dispatch.sh`（`dev_relay_result`）和 `lib/devtool_porcelain.sh` 的 `dev_emit_*` 族是 **leaf-pure module**：函数绝不 exit，返回 0（继续）/ 1（已诊断或编码失败），由 `cmd_dev` 据返回码 `exit 1`。`exit_contract` Y 规则覆盖（leaf-pure basename 归属以其配置为权威）。
- **exit 只在 `cmd_dev`（L1 exit seam）**这条 dev 表面不变量保持：所有 `lib/devtool_*.sh`（含新 dispatch/porcelain/build）都不直接 exit。未来 explorer 看到 `dev_relay_result` 返回 1 而 `cmd_dev` 再 `exit 1`，**不应视为冗余**而把 exit 下沉进 helper。
- porcelain stdout 契约的失败语义（哪个 exit-code 契约值、哪条 remedy line）仍是 `cmd_dev` 的职责——leaf-pure helper 只诊断（打 stderr + 返回码），不决定 exit-code 契约。前置缺失（如 build 未 modified → exit 3 + remedy）归 `cmd_dev`，不归 relay。
- 本 ADR 不约束未来**新类型**的 exit seam 决策——只锁定 dev dispatch/emit 这两族 helper 的 leaf-pure 归属。若未来出现"helper own exit 明显更优"的新场景，重开评审。
