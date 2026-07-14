#!/usr/bin/env python3
"""recipe 元数据索引生成器: tinfoil 取当前 bblayers 所有 target recipe 的 PN/layer/SUMMARY,输出 JSONL 到 stdout。

layer 来源: BBFILE_COLLECTIONS + BBFILE_PATTERN_<coll>(权威 BitBake layer collection 映射,
不把 recipe 路径 basename 当 layer 名)。summary 缺省回退 DESCRIPTION,压单行。
layer 取不到则跳过该 recipe + stderr warn(不糊)。parse 失败 → exit 非 0 + stderr 诊断。

需在 bitbake build env(由调用者 _devtool_env_exec 保证 source setup)。
参考 tools/parse_bitbake_deps.py 的 tinfoil 模式。
"""
import argparse
import json
import os
import re
import sys


def parse_args():
    ap = argparse.ArgumentParser(description="Generate recipe metadata index (JSONL) via tinfoil.")
    ap.add_argument("--build-dir", required=True, help="bitbake build directory (contains conf/bblayers.conf)")
    ap.add_argument("--machine", required=True)
    return ap.parse_args()


def main():
    args = parse_args()
    build_dir = os.path.abspath(args.build_dir)
    # build_dir 通常是 <openbmc>/build/<machine>; 取两层上得 openbmc 根
    openbmc_dir = os.path.dirname(os.path.dirname(build_dir))
    bitbake_lib = os.path.join(openbmc_dir, "bitbake", "lib")
    if not os.path.isdir(bitbake_lib):
        print(f"Error: bitbake lib not found at {bitbake_lib}. "
              f"Ensure --build-dir points to a valid build directory.", file=sys.stderr)
        return 2
    sys.path.insert(0, bitbake_lib)
    try:
        from bb.tinfoil import Tinfoil
    except ImportError:
        print(f"Error: cannot import bb.tinfoil from {bitbake_lib}. "
              f"Ensure bitbake is present in the OpenBMC tree.", file=sys.stderr)
        return 2

    # Tinfoil.prepare() 往 stdout 喷 cache/parsing 日志; 保存真 stdout, 期间重定向到 stderr,
    # 只在 print JSONL 时切回真 stdout(porcelain: stdout 纯 JSONL)。
    real_stdout = sys.stdout
    sys.stdout = sys.stderr
    emitted = 0
    skipped = 0
    try:
        with Tinfoil() as tinfoil:
            print("Initializing Tinfoil (loading bitbake cache)...", file=sys.stderr)
            tinfoil.prepare(config_only=False)

            # layer 权威映射: BBFILE_COLLECTIONS + BBFILE_PATTERN_<coll>
            collections = (tinfoil.config_data.getVar("BBFILE_COLLECTIONS") or "").split()
            layer_rx = {}
            for coll in collections:
                pat = tinfoil.config_data.getVar(f"BBFILE_PATTERN_{coll}")
                if not pat:
                    continue
                try:
                    layer_rx[coll] = re.compile(pat)
                except re.error as e:
                    print(f"WARN: invalid BBFILE_PATTERN_{coll}={pat!r}: {e}", file=sys.stderr)
                    continue

            def get_layer(fn):
                for coll, rx in layer_rx.items():
                    if rx.search(fn):
                        return coll
                return None

            # 排除 native/sdk/cross/canadian 变体(用 substring 覆盖 -cross-/-cross-canadian-/canadian- 等,
            # 比 suffix/prefix 更全;评审指出 binutils-cross-arm/gcc-cross-canadian-arm 漏过滤)
            _skip_substrings = ("-native", "-cross", "-crosssdk-", "-cross-canadian-", "nativesdk-", "canadian-")
            for recipe in tinfoil.all_recipes():
                pn = recipe.pn
                if any(s in pn for s in _skip_substrings):
                    continue
                try:
                    d = tinfoil.parse_recipe(pn)
                except Exception as e:
                    print(f"WARN: parse_recipe failed for {pn}: {e}", file=sys.stderr)
                    skipped += 1
                    continue
                if d is None:
                    skipped += 1
                    continue
                recipe_file = d.getVar("FILE") or ""
                layer = get_layer(recipe_file)
                if not layer:
                    print(f"WARN: layer not found for {pn} ({recipe_file}), skipped (不糊 basename)",
                          file=sys.stderr)
                    skipped += 1
                    continue
                summary = (d.getVar("SUMMARY") or d.getVar("DESCRIPTION") or "")
                summary = " ".join(summary.split())  # 压单行
                rec = {"recipe": pn, "layer": layer, "summary": summary}
                sys.stdout = real_stdout
                print(json.dumps(rec, ensure_ascii=False))
                sys.stdout = sys.stderr
                emitted += 1
    finally:
        sys.stdout = real_stdout

    print(f"emitted={emitted} skipped={skipped}", file=sys.stderr)
    return 0 if emitted > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
