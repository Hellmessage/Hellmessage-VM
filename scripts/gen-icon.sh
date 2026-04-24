#!/usr/bin/env bash
# 从 Resources/AppIcon-src.png (至少 1024x1024) 生成 Resources/AppIcon.icns
# 源图不存在时仅打印提示, 不阻断构建

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/AppIcon-src.png"
OUT="$ROOT/Resources/AppIcon.icns"
SET="$ROOT/Resources/AppIcon.iconset"

if [ ! -f "$SRC" ]; then
    if [ ! -f "$OUT" ]; then
        echo "ℹ 未找到 Resources/AppIcon-src.png, .app 将暂无图标"
        echo "  保存一张 1024x1024 PNG 到该路径后再 make build, 自动生成 .icns"
    fi
    exit 0
fi

# 源图未变则跳过 (src 比 icns 旧时)
if [ -f "$OUT" ] && [ "$SRC" -ot "$OUT" ]; then
    exit 0
fi

echo "→ 生成 AppIcon.icns"
rm -rf "$SET"
mkdir -p "$SET"

# Apple 标准 iconset 尺寸
declare -a SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
    size="${entry%%:*}"
    name="${entry##*:}"
    sips -z "$size" "$size" "$SRC" --out "$SET/$name" > /dev/null
done

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$SET"

echo "✔ $OUT"
