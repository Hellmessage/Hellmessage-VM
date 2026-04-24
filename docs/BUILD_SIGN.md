# 构建与签名

## 目标

- 空白 Mac 上 `make build` 一条命令跑通, 除 Xcode Command Line Tools + Apple Developer 证书外**零手动依赖**
- SwiftPM 是唯一构建系统, 产物由 `scripts/bundle.sh` 组装 + 签名成 `.app`
- Xcode 开发期可用 `xed Package.swift` 直接打开, 不强制走 Makefile

## 工具依赖

| 工具 | 必需 | 备注 |
|---|---|---|
| Xcode 16+ (Swift 6) | ✅ | 安装 Xcode Command Line Tools 即可 |
| Apple Development 证书 | ✅ | 账号登录 Xcode 自动生成 |
| `swift` (SwiftPM 6) | ✅ | 随 Xcode 带 |
| `codesign` | ✅ | 系统自带 |
| `plutil` / `PlistBuddy` | ✅ | 系统自带 |
| Homebrew / vendor / 外部 C 项目 | ❌ | **禁止引入** |

## 目录布局

```
HVM/
├── Package.swift                     — SwiftPM manifest, 唯一构建入口
├── Sources/
│   ├── HVMCore/                      — 基础库
│   ├── HVMBundle/
│   ├── HVMStorage/
│   ├── HVMBackend/
│   ├── HVMDisplay/
│   ├── HVMInstall/
│   ├── HVMNet/
│   ├── HVMIPC/
│   ├── HVM/                          — App target (executable, SwiftUI 入口)
│   ├── hvm-cli/
│   └── hvm-dbg/
├── Tests/
│   └── HVM*Tests/
├── Resources/
│   ├── HVM.entitlements              — entitlement plist
│   ├── Info.plist.template           — App 的 Info.plist 模板
│   ├── AppIcon.icns
│   └── embedded.provisionprofile     — bridged entitlement 通过后放入
├── scripts/
│   ├── bundle.sh                     — 组装 .app, 签名
│   ├── gen-icon.sh                   — 从 PNG 生成 .icns
│   └── verify-build.sh               — smoke test: 能启动, Info.plist 正确
├── build/                            — 构建产物输出(gitignored)
│   ├── HVM.app
│   ├── hvm-cli
│   └── hvm-dbg
├── Makefile
├── CLAUDE.md
├── README.md
└── docs/
```

## Package.swift 结构

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HVM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HVM",     targets: ["HVM"]),
        .executable(name: "hvm-cli", targets: ["hvm-cli"]),
        .executable(name: "hvm-dbg", targets: ["hvm-dbg"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.4.0"),
    ],
    targets: [
        .target(name: "HVMCore"),
        .target(name: "HVMBundle",   dependencies: ["HVMCore"]),
        .target(name: "HVMStorage",  dependencies: ["HVMCore"]),
        .target(name: "HVMNet",      dependencies: ["HVMCore"]),
        .target(name: "HVMDisplay",  dependencies: ["HVMCore"]),
        .target(name: "HVMBackend",  dependencies: ["HVMCore","HVMBundle","HVMStorage","HVMNet","HVMDisplay"]),
        .target(name: "HVMInstall",  dependencies: ["HVMBackend"]),
        .target(name: "HVMIPC",      dependencies: ["HVMCore"]),

        .executableTarget(
            name: "HVM",
            dependencies: ["HVMBackend","HVMInstall","HVMIPC","HVMDisplay"]
        ),
        .executableTarget(
            name: "hvm-cli",
            dependencies: [
                "HVMBackend","HVMInstall","HVMIPC",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "hvm-dbg",
            dependencies: [
                "HVMIPC","HVMCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(name: "HVMBundleTests",  dependencies: ["HVMBundle"]),
        .testTarget(name: "HVMStorageTests", dependencies: ["HVMStorage"]),
        .testTarget(name: "HVMBackendTests", dependencies: ["HVMBackend"]),
        .testTarget(name: "HVMNetTests",     dependencies: ["HVMNet"]),
    ]
)
```

## Makefile

```makefile
CONFIGURATION ?= release
BUILD_DIR     := build
SWIFTPM_DIR   := .build
TEAM_ID       := Q7L455FS97
SIGN_IDENTITY := "Apple Development"
ENTITLEMENTS  := Resources/HVM.entitlements

.PHONY: all build bundle sign clean test verify

all: build

build: bundle

# 1. SwiftPM 编译全部 executable
compile:
	swift build -c $(CONFIGURATION) --product HVM
	swift build -c $(CONFIGURATION) --product hvm-cli
	swift build -c $(CONFIGURATION) --product hvm-dbg

# 2. 组装 .app + 签名
bundle: compile
	bash scripts/bundle.sh $(CONFIGURATION) $(SIGN_IDENTITY)

# 3. smoke test
verify:
	bash scripts/verify-build.sh

test:
	swift test

clean:
	rm -rf $(BUILD_DIR) $(SWIFTPM_DIR)
```

## scripts/bundle.sh

### 职责

1. 从 SwiftPM 产物目录复制 `HVM` / `hvm-cli` / `hvm-dbg` 到 `build/`
2. 组装 `build/HVM.app`:
   - `Contents/MacOS/HVM` (主 executable)
   - `Contents/Info.plist` (填入版本号、bundle ID)
   - `Contents/Resources/AppIcon.icns`
   - `Contents/Resources/HVM.entitlements` 留着参考, 不实际运行时读
   - `Contents/embedded.provisionprofile` (若存在)
3. `codesign` 签名 .app 及内部 binary

### 伪代码

```bash
#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
SIGN="${2:-Apple Development}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
SWIFT_BIN="$ROOT/.build/arm64-apple-macosx/$CONFIG"
APP="$BUILD/HVM.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1. 拷 binary
cp "$SWIFT_BIN/HVM"     "$APP/Contents/MacOS/HVM"
cp "$SWIFT_BIN/hvm-cli" "$BUILD/hvm-cli"
cp "$SWIFT_BIN/hvm-dbg" "$BUILD/hvm-dbg"

# 2. 生成 Info.plist
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.1")
BUILD_NUM=$(git rev-list --count HEAD 2>/dev/null || echo "1")
sed \
  -e "s/__VERSION__/$VERSION/" \
  -e "s/__BUILD__/$BUILD_NUM/" \
  "$ROOT/Resources/Info.plist.template" > "$APP/Contents/Info.plist"
plutil -convert xml1 "$APP/Contents/Info.plist"

# 3. Resources
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# 4. provisioning profile (只在已审批 bridged 后才存在)
if [ -f "$ROOT/Resources/embedded.provisionprofile" ]; then
    cp "$ROOT/Resources/embedded.provisionprofile" "$APP/Contents/embedded.provisionprofile"
fi

# 5. 签名: 先内部 binary, 再 .app
codesign --force --options runtime \
         --sign "$SIGN" \
         --entitlements "$ROOT/Resources/HVM.entitlements" \
         "$APP/Contents/MacOS/HVM"

codesign --force --options runtime \
         --sign "$SIGN" \
         --entitlements "$ROOT/Resources/HVM.entitlements" \
         "$APP"

# CLI / dbg 也要签, 否则 hardened runtime 下无法运行
codesign --force --options runtime --sign "$SIGN" \
         --entitlements "$ROOT/Resources/HVM.entitlements" \
         "$BUILD/hvm-cli"
codesign --force --options runtime --sign "$SIGN" \
         --entitlements "$ROOT/Resources/HVM.entitlements" \
         "$BUILD/hvm-dbg"

# 6. 验证
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --verbose=4 --type execute "$APP" || echo "(spctl fail ok, 未公证)"

echo "✔ 构建完成: $APP"
```

### 签名身份选择

`scripts/bundle.sh` 按以下优先级选签名身份:

1. **显式 `$SIGN_IDENTITY`** (非 `auto`) — 用户通过 `SIGN_IDENTITY="Apple Development" make build` 指定
2. **Apple Development** — 自动探测, 仅当 `security find-identity -v -p codesigning` 列出该身份 (即证书链完整且被信任) 才选用
3. **ad-hoc `-`** — 上述都不可用时的默认方案, 也是本项目**推荐的个人自用签名方式**

三种方式对本项目都等价可用:

| 方式 | VZ entitlement | 跨机分发 | 维护 |
|---|---|---|---|
| Apple Development | ✅ 生效 | 能被其他 Mac Gatekeeper 放行(需同 Team) | 需保持证书链 / 中间证书 / 信任 |
| ad-hoc (`-`) | ✅ 生效 | 其他 Mac 被 Gatekeeper 拦, 本机无感 | 零 |

**选型默认**: ad-hoc。CLAUDE.md 已约束 "不公证不分发, 仅自机运行", ad-hoc 正好匹配该定位且无证书环境依赖, 空白 Mac 上 `make build` 总能跑通。

### hardened runtime

- 真实证书(Apple Development)叠加 `--options runtime` (hardened runtime), 与 Apple 公证流程的前置条件兼容(虽然本项目不公证)
- ad-hoc 签名**不叠加** `--options runtime`, 避免某些 macOS 版本下与 entitlement 组合时出现启动限制

### 签名约束(CLAUDE.md)

- 签名相关代码 / 日志**不得输出**: team ID、证书 SHA、私钥路径
- `scripts/bundle.sh` 的输出限于: 签名方式提示(如"使用 ad-hoc 签名")、最终 "✔ 构建完成"、产物路径
- Makefile 历史上出现过 `TEAM_ID` 字段, 已移除, **不再向环境变量 / stdout / 日志文件**任何输出 Team ID

## Info.plist 模板

`Resources/Info.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>HVM</string>
    <key>CFBundleDisplayName</key>          <string>HVM</string>
    <key>CFBundleIdentifier</key>           <string>com.hellmessage.vm</string>
    <key>CFBundleVersion</key>              <string>__BUILD__</string>
    <key>CFBundleShortVersionString</key>   <string>__VERSION__</string>
    <key>CFBundleExecutable</key>           <string>HVM</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.developer-tools</string>
    <key>NSMainNibFile</key>                <string></string>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
</dict>
</plist>
```

## Entitlements

`Resources/HVM.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>

    <!-- bridged 审批通过后取消下面注释 -->
    <!--
    <key>com.apple.vm.networking</key>
    <true/>
    -->
</dict>
</plist>
```

审批通过后的操作见 [ENTITLEMENT.md](ENTITLEMENT.md)。

## 版本号策略

- `CFBundleShortVersionString` = `git describe --tags --always --dirty`, 例: `v0.3.2-5-g9a8b7c6`
- `CFBundleVersion` = `git rev-list --count HEAD`, 单调递增
- 开发期无 tag 时默认 `0.0.1`, 不阻塞构建

## Xcode 兼容路径

```bash
xed Package.swift
```

在 Xcode 里:

- 可编辑, 可补全, 可 LLDB 调试
- 点 Run 产出裸 `.build/.../HVM` 二进制, **无 entitlement**, 只能启动 UI 不能用 VZ(VZVirtualMachine 构造会报权限拒绝)
- **真实运行必须 `make build`**, 出带 entitlement 签名的 .app
- Xcode 路径仅用于: UI 编辑、断点调试非 VZ 部分、快速语法迭代

## 构建矩阵

| 命令 | 产物 | 用途 |
|---|---|---|
| `make build` | `build/HVM.app`, `build/hvm-cli`, `build/hvm-dbg` | **权威, 可跑 VM** |
| `swift build` | `.build/arm64-apple-macosx/debug/...` | SwiftPM 开发测试 |
| `swift test` | 测试二进制 | 单元测试 |
| `xed + Run` | Xcode 内 DerivedData | UI 迭代, **不可跑 VM** |

## clean

```bash
make clean
```

删:
- `build/`
- `.build/`
- `DerivedData`(Xcode 内手动删, 不自动)

## CI 策略(占位)

暂不做 CI。理由:

1. GitHub Actions macOS runner 无 VZ 能力(VM 里跑 VM), 跑不了集成测试
2. 签名需要证书, CI 签名要处理 keychain 自动化, 成本高
3. 个人项目, 每次 local `make build` 足矣

未来若加 CI, 方向:
- 只跑 `swift build` + `swift test`, 不产 `.app`
- 不做发布流水线, 构建靠本地

## 安装到系统

MVP 不自动装到 `/Applications/`。用户自己:

```bash
cp -R build/HVM.app /Applications/
# CLI 和 dbg 可选装到 PATH
ln -s "$PWD/build/hvm-cli" /usr/local/bin/
ln -s "$PWD/build/hvm-dbg" /usr/local/bin/
```

## 不做什么

1. **不引 Homebrew 依赖**(CLAUDE.md 硬约束)
2. **不引 CocoaPods / Carthage / vendor dylib**
3. **不做 Developer ID 公证 / notarize**: 不分发, 只自用
4. **不做 TestFlight / App Store**: 不上架
5. **不做自更新机制**(Sparkle 等)
6. **不写 Xcode `.xcodeproj`**: SwiftPM 足矣, Xcode 打开 Package.swift 即可
7. **不嵌入 Python / Ruby 脚本作为构建依赖**: scripts/ 只有 bash

## 未决事项

| 编号 | 问题 | 默认方案 | 决策时机 |
|---|---|---|---|
| I1 | 是否生成 `.dSYM` | 默认生成, `make build` 保留在 `build/HVM.app.dSYM/` | 已决 |
| I2 | 是否引入 `swift-format` / SwiftLint | 不引入 lint, 靠 code review | 已决 |
| I3 | release vs debug 默认 | `make build` = release, `make dev` = debug | 已决 |

## 相关文档

- [ENTITLEMENT.md](ENTITLEMENT.md) — entitlement 细节, bridged 审批 SOP
- [ARCHITECTURE.md](ARCHITECTURE.md) — 模块划分, 映射到 SwiftPM target

---

**最后更新**: 2026-04-25
