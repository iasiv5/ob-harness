#!/usr/bin/env bash
# lib/devtool_search.sh — recipe 元数据检索/JSONL 缓存/stale 检测/refresh/clear. 术语见 CONTEXT.md.
# Exit: leaf-no-exit（leaf-pure module）; 调用者负责 exit-code/remedy/诊断.

# === 函数区(T3 填充: devtool_search_list/refresh/cache_state + devtool_recipes_clear_cache + 路径函数) ===
