#!/usr/bin/env bash
# s 安装脚本：把 s 装到 ~/.local/bin，并安装 zsh 补全。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

echo "• 安装 s → $BIN_DIR/s"
mkdir -p "$BIN_DIR"
install -m 0755 "$HERE/s" "$BIN_DIR/s"

# PATH 检查
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "⚠️  $BIN_DIR 不在 PATH 里，请把这行加进 ~/.zshrc：export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# zsh 补全：优先 oh-my-zsh 的 completions 目录，否则用 ~/.zsh/completions
COMP_DST=""
if [ -d "$HOME/.oh-my-zsh/completions" ]; then
  COMP_DST="$HOME/.oh-my-zsh/completions/_s"
else
  COMP_DST="$HOME/.zsh/completions/_s"
  mkdir -p "$HOME/.zsh/completions"
  echo "• 补全目录：$HOME/.zsh/completions"
  echo "  若尚未配置，请在 ~/.zshrc 的 compinit 之前加："
  echo "    fpath=(\$HOME/.zsh/completions \$fpath)"
fi
echo "• 安装 zsh 补全 → $COMP_DST"
install -m 0644 "$HERE/completions/_s" "$COMP_DST"

# 依赖提示
echo
echo "依赖检查："
command -v ssh     >/dev/null 2>&1 && echo "  ✓ ssh"      || echo "  ✗ ssh（必需）"
command -v sshpass >/dev/null 2>&1 && echo "  ✓ sshpass"  || echo "  - sshpass 未装（密码登录需要：brew install sshpass）"
command -v fzf     >/dev/null 2>&1 && echo "  ✓ fzf"      || echo "  - fzf 未装（s pick 需要：brew install fzf）"
command -v nc      >/dev/null 2>&1 && echo "  ✓ nc"       || echo "  - nc 未装（s ping 需要）"
command -v security>/dev/null 2>&1 && echo "  ✓ security（macOS Keychain）" || echo "  - 非 macOS：密码存储不可用，密钥登录不受影响"

echo
echo "✅ 完成。开个新终端或执行 exec zsh，然后敲 s 试试。"
