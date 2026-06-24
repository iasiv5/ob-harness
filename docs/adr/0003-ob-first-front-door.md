# ob 优先：ob 作为 OpenBMC 环境动作的统一前门

`ob` 功能持续增长（init/build/status/start-qemu/stop-qemu），默认调用方是 agent。为避免 agent 各自手搓环境动作（手动 clone、裸 `bitbake`、手起 QEMU）导致行为发散，确立“ob 优先”：agent 做环境生命周期动作前先查 `ob --help`，有就走 `ob <cmd>`，仅当 `exit 1` 真失败且 ob 确无此能力时才手动兜底（`exit 2` 取消、`exit 3` 前置缺失都不算失败，不得据此绕过 ob）。判定锚定 `ob --help` 为唯一权威能力清单，由 `tests/protocol/usage_dispatch_sync.sh` 断言其与 dispatch 一致来防漂移。`exit 3` 是多义码，消费侧约定「诊断行 + remedy line」两段式把“成败 + 下一步”喂给 agent，而不另建 JSON 结构化接口（正向落点见 Considered Options 3）；术语与约束见 `CONTEXT.md`。约定分两层落地：`AGENTS.md`「Working Mode」放最小守卫（常驻），完整协议在 `rules/skills/bestpractice_06-ob_first.md`（按需）。

Status: accepted

## Considered Options

1. **放任 agent 直连最短路径** — 不立约定，agent 想手动就手动。最简单，但能力发散、不可维护，且违背"ob CLI 默认由 agent 调用"的设计初衷。
2. **只做软偏好** — 写一句"建议优先 ob"但不定退出码回退语义。agent 会在 `exit 3`（前置缺失）时误判为失败并转手动绕过 `ob`，约定形同虚设。
3. **能力清单另建结构化接口（`ob help --json` / `ob commands`）** — 更贴 A12，但与 `usage()` 形成双源、需同步，`--help` 已被发现漂移过一次（`--skip-deps` 缺失），双源只会加剧漂移。故取“退出码骨架 + 诊断行/remedy line”两段式而非结构化输出；除非将来实测 agent 解析不了散文，否则维持单源。
4. **用 hook 强制（SessionStart 提醒 / PreToolUse 命令拦截）** — SessionStart 与常驻 `AGENTS.md` 守卫重复，且现有 hook 在 Linux 下是 no-op；PreToolUse 拦截可行性未证实且误报率高，会挡正当的裸 `bitbake` 调试。正确落点是约定层 + CI 闸，不是 hook。
5. **完整协议常驻每会话加载（写进 AGENTS.md 或新 `rules/07_*.md`）** — 可靠性最高，但真正需要常驻的只有几行守卫，全表常驻让每会话付额外上下文成本。退而取两层：守卫常驻、细节按需。
