#!/usr/bin/env bash
# build.sh — herdr fork 一键构建脚本
#
# 流程：cargo build --release → adhoc 签名 → （可选）跑 detect 测试 → （可选）部署
#
# 已处理的坑：
#   - 工具链 PATH：homebrew（zig）+ rustup toolchain（cargo 1.96.1）
#   - zig 拉依赖被本地代理 400 拦截时，自动绕过代理预热 zig 缓存后重试
#   - 本地编译产物必须 adhoc 重签，否则 macOS Taskgated 直接 SIGKILL
#     （症状：无任何输出、exit 137）
#
# 用法：
#   ./build.sh              # 只构建 + 签名
#   ./build.sh --test       # 构建 + 跑 detect 测试
#   ./build.sh --install    # 构建 + 部署到 ~/.local/bin/herdr（重启 herdr 生效）
#   ./build.sh --test --install
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SRC="$REPO_DIR/target/release/herdr"
BIN_DST="$HOME/.local/bin/herdr"
BIN_PREV="$HOME/.local/bin/herdr-prev"
VENDOR_DIR="$REPO_DIR/vendor/libghostty-vt"
BUILD_LOG="/tmp/herdr-build.log"
cd "$REPO_DIR"

# --- 工具链：homebrew（zig）+ rustup（cargo 版本随仓库 rust-toolchain.toml）---
export PATH="/opt/homebrew/bin:$PATH"
TOOLCHAIN_BIN="$(dirname "$(rustup which cargo 2>/dev/null)" 2>/dev/null || true)"
[ -n "${TOOLCHAIN_BIN:-}" ] && export PATH="$TOOLCHAIN_BIN:$PATH"
command -v cargo >/dev/null 2>&1 || { echo "error: cargo 不可用（先装 rustup 并跑一次 rustup toolchain install）" >&2; exit 1; }
command -v zig    >/dev/null 2>&1 || { echo "error: zig 不可用（brew install zig）" >&2; exit 1; }

INSTALL=0
RUN_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --test)    RUN_TESTS=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "未知参数: ${arg} （用法见 --help）" >&2; exit 1 ;;
  esac
done

# --- 构建 ---
echo "==> cargo build --release"
if ! cargo build --release 2>&1 | tee "$BUILD_LOG" | tail -3; then
  if grep -q "400 Bad Request" "$BUILD_LOG"; then
    echo "==> zig 拉依赖被代理拦截，绕过代理预热 zig 缓存后重试"
    (cd "$VENDOR_DIR" && env -u http_proxy -u https_proxy -u all_proxy \
       -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY zig build --fetch)
    cargo build --release 2>&1 | tail -3
  else
    tail -20 "$BUILD_LOG" >&2
    exit 1
  fi
fi

# --- 签名（缺失会导致 exit 137 静默被杀）---
echo "==> codesign (adhoc)"
codesign --force --sign - "$BIN_SRC"

"$BIN_SRC" --version || { echo "error: 构建产物无法运行" >&2; exit 1; }

# --- 测试（可选）---
if [[ "$RUN_TESTS" == 1 ]]; then
  echo "==> cargo test (detect)"
  cargo test --release detect:: 2>&1 | grep -E "test result" || { echo "error: 测试未产出结果" >&2; exit 1; }
fi

# --- 部署（可选）---
if [[ "$INSTALL" == 1 ]]; then
  if [[ -f "$BIN_DST" ]]; then
    cp "$BIN_DST" "$BIN_PREV"   # 滚动备份上一版，便于回退
  fi
  cp "$BIN_SRC" "$BIN_DST"
  echo "==> 已部署 ${BIN_DST} （上一版在 ${BIN_PREV}）"
  echo "    重启 herdr 生效：herdr server stop && herdr workspace list"
else
  echo "==> 构建完成：$BIN_SRC"
  echo "    部署：$0 --install"
fi
