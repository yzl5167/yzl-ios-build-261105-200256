#!/usr/bin/env bash
# 把 engine/fork-patches 里的三处补丁应用到 Amethyst 检出目录。
# 用法：bash engine/apply-fork-patches.sh <amethyst-checkout-dir>
# 幂等：重复执行时已打过的补丁会跳过（以特征串为准）。
set -euo pipefail

AMETHYST_DIR="${1:?用法: apply-fork-patches.sh <amethyst-checkout-dir>}"
MARKER="YZL_LAUNCH_PLAN"

echo "[patch] target: $AMETHYST_DIR"

PL="JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java"

if grep -q "$MARKER" "$AMETHYST_DIR/$PL"; then
  echo "[patch] PojavLauncher.java 已含 YZL 分支，跳过"
else
  python3 - "$AMETHYST_DIR/$PL" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
needle = "public static void launchMinecraft(String[] args) throws Throwable {"
if needle not in src:
    sys.exit("launchMinecraft 方法未找到，Amethyst 版本可能已变化，需人工核对 fork 补丁")
branch = needle + '''
    // ---- YZL branch: fully-resolved launch plan from the YZL launcher UI ----
    String yzlPlanPath = System.getenv("YZL_LAUNCH_PLAN");
    if (yzlPlanPath != null && !yzlPlanPath.isEmpty()) {
        net.kdt.pojavlaunch.yzl.YZLGameEntry.launch(new File(yzlPlanPath));
        return;
    }
'''
src = src.replace(needle, branch, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("[patch] PojavLauncher.java: YZL 分支已插入")
PY
fi

# 二进制名解耦：GLFW.java / UIKit.java 的 System.load(BUNDLE_PATH/固定名)
for f in "JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java" \
         "JavaApp/src/launcher/net/kdt/pojavlaunch/uikit/UIKit.java"; do
  target="$AMETHYST_DIR/$f"
  if [ ! -f "$target" ]; then
    echo "[patch] WARN: $f 不存在，跳过（fork 结构变化，需人工核对）"
    continue
  fi
  if grep -q "YZL_ENGINE_BINARY" "$target"; then
    echo "[patch] $f 已解耦二进制名，跳过"
  else
    python3 - "$target" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()
needle = 'System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst"'
replacement = '(System.getenv("YZL_ENGINE_BINARY") != null ? System.getenv("YZL_ENGINE_BINARY") : System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst")'
if needle not in src:
    sys.exit(f"二进制名加载点在 {path} 中未找到，需人工核对")
src = src.replace(needle, replacement)
with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print(f"[patch] {path}: 二进制名已解耦")
PY
  fi
done

# YZLGameEntry.java（fork 桥的 Java 侧实现，独立文件，直接落盘）
ENTRY_DIR="$AMETHYST_DIR/JavaApp/src/launcher/net/kdt/pojavlaunch/yzl"
mkdir -p "$ENTRY_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/fork-patches/yzl/YZLGameEntry.java" ]; then
  cp "$SCRIPT_DIR/fork-patches/yzl/YZLGameEntry.java" "$ENTRY_DIR/YZLGameEntry.java"
  echo "[patch] YZLGameEntry.java 已放置"
else
  echo "[patch] WARN: engine/fork-patches/yzl/YZLGameEntry.java 缺失，YZL 启动分支会编译失败"
fi

echo "[patch] done"
