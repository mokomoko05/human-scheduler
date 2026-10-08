#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh
TARGET="$HOME/Applications/Scheduler.app"
OLD="$HOME/Applications/Dayleaf.app"
if pgrep -f "$TARGET/Contents/MacOS/Scheduler" >/dev/null 2>&1 || pgrep -f "$OLD/Contents/MacOS/Dayleaf" >/dev/null 2>&1; then
    echo "请先退出 Scheduler，再重新运行安装脚本。"
    exit 1
fi
mkdir -p "$HOME/Applications"
ditto "dist/Scheduler.app" "$TARGET"
"$TARGET/Contents/MacOS/Scheduler" --configure-login
# 改名前的旧版：登录启动已指向新版，旧的 Dayleaf.app 不再需要。
if [ -d "$OLD" ]; then rm -rf "$OLD"; echo "已移除改名前的旧版：$OLD"; fi
# 命令行工具：链接到默认 PATH 里的 ~/.local/bin，任何终端都能直接运行 sched。
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "$TARGET/Contents/Resources/bin/sched" "$BIN_DIR/sched"
# zsh 自带一个叫 sched 的内置命令，在 zsh 里会盖住 PATH 里的 sched；同一个程序再以 scheduler 的名字提供，所有 shell 里都能直接用。
ln -sf "$TARGET/Contents/Resources/bin/sched" "$BIN_DIR/scheduler"
echo "已安装命令行工具：$BIN_DIR/sched（zsh 里请用 scheduler，或在 ~/.zshrc 加一行 disable sched）"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "提示：$BIN_DIR 不在当前 PATH 里，请把 export PATH=\"\$HOME/.local/bin:\$PATH\" 加进 ~/.zshrc。" ;;
esac
if open "$TARGET"; then
    echo "已安装并请求打开 Scheduler；登录启动状态可在应用右上角菜单查看。"
else
    echo "安装完成。当前环境无法打开桌面应用，请在 Finder 中打开：$TARGET"
fi
