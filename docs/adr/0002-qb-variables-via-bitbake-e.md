# QB 变量通过 `bitbake -e` 解析，不做 fallback

`ob start-qemu` 需要从 OpenBMC machine conf 中读取 `QB_MACHINE`（QEMU machine 名）和 `QB_MEM`（内存大小）来构建 QEMU 启动命令。这些变量使用 BitBake override 语法（`QB_MACHINE:romulus = "-machine romulus-bmc"`），经过 include 链和 override 优先级层层叠加。ob-harness 选择通过 `source setup <machine> && bitbake -e` 获取最终展开值，而不是用 grep/sed 自行解析。代价是每次启动多几秒 BitBake 环境加载时间，但保证 100% 准确。同时决定：如果 `QB_MACHINE` 或 `QB_MEM` 不存在，直接报错退出，ob-harness 不提供 fallback 默认值——这些参数的定义是 OpenBMC 层的职责，不是工具的职责。
