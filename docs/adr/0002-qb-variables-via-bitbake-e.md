# QB variable values are resolved via `bitbake -e`

`ob start-qemu` 需要读取 OpenBMC machine conf 中最终生效的 QB variable 值，例如 `QB_MACHINE`、`QB_MEM` 和 `QB_SYSTEM_NAME`。这些值可能经过 BitBake override 语法和 include 链展开，因此凡是被称为 `QB_*` 的值，都必须来自 `source setup <machine> && bitbake -e` 的最终展开结果；ob-harness 不用 grep/sed 自行解析 machine conf，也不把 fallback 伪装成 QB variable。

Status: accepted, amended by ADR-0007 for `start-qemu` missing-input policy

## Consequences

- ADR-0002 只拥有 QB variable 的取值来源真实性：`QB_*` 值来自 BitBake 展开结果。
- QB input 缺失后的兼容策略不再由 ADR-0002 决定；`ob start-qemu` 的缺失输入处理由 ADR-0007 的 `QEMU launch profile` 决定。
- legacy machine-name fallback、空 `QB_MEM` 省略 `-m` 参数、legacy AST2600 fallback 等兼容行为只能产出 `QEMU_LAUNCH_*`，不能回填或命名为 `QB_*`。
