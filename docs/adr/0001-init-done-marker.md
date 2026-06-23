# init-done marker as ob init completion signal

`ob build` 需要知道哪些 machine 经过了完整的 `ob init` 流程。没有单一的现有文件能可靠表示"全部 8 步完成"：`local.conf` 在 step 3 就存在，`machine snapshot` 在 step 6，`report.txt` 是最后产出但通过 `tee` 写入可能被 Ctrl+C 截断。我们选择在 `ob init` 的 `main()` 末尾、`print_report()` 之后原子写入 `<machine>.init-done`，重跑时先删除再重新写入。这比复用任何现有文件语义更干净：report 是状态报告不是完成确认，`machine snapshot` 记录的是 source/deps snapshot 不是流程完成状态，两者混用会踩 Ctrl+C 中断导致的假阳性坑。

Status: accepted

## Considered Options

1. **复用 report.txt 存在性** — step 8 最后产出，但 `tee` 可能截断；且 report 的语义是"报告"不是"完成"
2. **复用 machine snapshot + externalsrc inc 同时存在** — 组合条件多，且 `machine snapshot`(step 6) 和 inc(step 7) 之间仍有中断窗口
3. **新增 .init-done 文件** — 语义明确，写入点在 `main()` 最后一行，任何中断都不会产生假阳性
