# HVM Makefile
# 唯一构建入口 (Xcode 打开 app/Package.swift 作为开发期辅助, 不做权威构建)

CONFIGURATION ?= release
BUILD_DIR     := build
PKG_DIR       := app
SWIFTPM_DIR   := $(PKG_DIR)/.build
# 签名身份: 空/auto = bundle.sh 自动探测 (Apple Development 优先, 否则 ad-hoc)
SIGN_IDENTITY ?= auto
ENTITLEMENTS  := $(PKG_DIR)/Resources/HVM.entitlements
# QEMU 后端产物 (由 scripts/qemu-build.sh 生成, 仓库 ignore, 详见 docs/QEMU_INTEGRATION.md)
# stage 即裁剪 + 签名 + LICENSE/MANIFEST 后的最终成品, bundle.sh 直接拷进 .app
# 不再有 third_party/qemu/ 中间 vendor 层
QEMU_STAGE    := third_party/qemu-stage
QEMU_BIN      := $(QEMU_STAGE)/bin/qemu-system-aarch64

.PHONY: all build bundle compile dev test verify clean help icon register-types qemu qemu-clean edk2 edk2-clean build-all xed install uninstall run-app

# 默认: release 模式 + 完整 .app 签名
all: build

build: bundle

help:
	@echo "HVM 构建命令:"
	@echo "  make build      — release 模式, 组装 .app + 签名 (默认; QEMU 缺则跳过嵌入)"
	@echo "  make dev        — debug 模式, 组装 .app + 签名"
	@echo "  make test       — 跑 swift test"
	@echo "  make verify     — smoke test, 验证 .app 可启动"
	@echo "  make icon       — 从 app/Resources/AppIcon-src.png 生成 AppIcon.icns"
	@echo "  make xed        — Xcode 打开 SwiftPM 包 (开发期辅助, 非权威构建路径)"
	@echo "  make install    — 把 build/HVM.app 安装到 /Applications/ (覆盖旧版)"
	@echo "  make uninstall  — 从 /Applications/ 卸载 HVM.app"
	@echo "  make run-app    — build + install + 重启 GUI 主进程 (开发期 dev loop; 不动正在运行的 VM host 子进程)"
	@echo "  make clean      — 清除 build/ 和 app/.build/"
	@echo
	@echo "QEMU 后端 (Win arm64 / 可选 Linux arm64; 详见 docs/QEMU_INTEGRATION.md):"
	@echo "  make edk2       — 拉 EDK2 + apply Win11 patch + 编译 (~5 分钟; 仅打包者跑; Win11 ARM64 装机必需)"
	@echo "  make edk2-clean — 清除 third_party/edk2-src/, third_party/edk2-stage/"
	@echo "  make qemu       — 装 brew 依赖 + 拉源码 + 编译 QEMU (10-30 分钟; 仅打包者跑)"
	@echo "  make qemu-clean — 清除 third_party/qemu-src/, third_party/qemu-stage/"
	@echo "  make build-all  — make edk2 + make qemu + make build (发布完整流程)"

# 1. SwiftPM 编译全部 executable
compile:
	swift build --package-path $(PKG_DIR) -c $(CONFIGURATION) --product HVM
	swift build --package-path $(PKG_DIR) -c $(CONFIGURATION) --product hvm-cli
	swift build --package-path $(PKG_DIR) -c $(CONFIGURATION) --product hvm-dbg

# 2. 生成图标 (源图不存在则跳过, 不阻断构建)
icon:
	@bash scripts/gen-icon.sh

# 3. 组装 .app + 签名
bundle: icon compile
	@CONFIGURATION=$(CONFIGURATION) SIGN_IDENTITY="$(SIGN_IDENTITY)" bash scripts/bundle.sh

# debug 变体
dev:
	@$(MAKE) build CONFIGURATION=debug

test:
	swift test --package-path $(PKG_DIR)

verify:
	@bash scripts/verify-build.sh

clean:
	rm -rf $(BUILD_DIR) $(SWIFTPM_DIR)
	@echo "✔ 已清除 build/ 与 $(SWIFTPM_DIR)/"

# EDK2 build (仅打包者跑; 详见 scripts/edk2-build.sh)
# 第一次跑会拉 edk2-stable202508 + submodules, apply Win11 patch, cross compile ~3-5 分钟
edk2:
	@bash scripts/edk2-build.sh

# 仅清 EDK2 相关产物, 不动 QEMU / SwiftPM
edk2-clean:
	rm -rf third_party/edk2-src third_party/edk2-stage
	@echo "✔ 已清除 third_party/edk2-src/, third_party/edk2-stage/"

# QEMU 后端构建 (仅打包者跑; 详见 scripts/qemu-build.sh 与 docs/QEMU_INTEGRATION.md)
# 第一次跑会自动装 Homebrew + 一组锁定 brew 依赖, 拉 v10.2.0 源码, 编译 ~10-30 分钟
# 优先用 third_party/edk2-stage/ 里的 patched firmware (给 Win11 ARM64); 没有则降级 QEMU 自带
qemu:
	@bash scripts/qemu-build.sh

# 仅清 QEMU 相关产物, 不动 SwiftPM 与 .app
qemu-clean:
	rm -rf third_party/qemu-src third_party/qemu-stage
	@echo "✔ 已清除 third_party/qemu-src/, third_party/qemu-stage/"

# 完整发布: 确保 EDK2 + QEMU 已就绪 (不存在则触发 make edk2 + make qemu) + 组装 .app 嵌入 QEMU
EDK2_BIN := third_party/edk2-stage/edk2-aarch64-code.fd
build-all:
	@if [ ! -f "$(EDK2_BIN)" ]; then \
		echo "ℹ EDK2 产物不存在 ($(EDK2_BIN)), 先跑 make edk2"; \
		$(MAKE) edk2; \
	fi
	@if [ ! -x "$(QEMU_BIN)" ]; then \
		echo "ℹ QEMU 产物不存在 ($(QEMU_BIN)), 先跑 make qemu"; \
		$(MAKE) qemu; \
	fi
	@$(MAKE) build

# Xcode 打开 SwiftPM 包 (开发期编辑/补全用, 产物无 entitlement 不签名; 真实运行仍走 make build)
xed:
	xed $(PKG_DIR)/Package.swift

# 安装到 /Applications/ (覆盖旧版). admin 用户对 /Applications 有写权限, 不需 sudo;
# /Applications/HVM.app 若存在则先删 (.app 是 directory, 不能直接 cp 覆盖).
# 安装后 lsregister 刷新 LaunchServices, 让 .hvmz 关联 + Spotlight 索引立即生效.
install: build
	@if [ ! -d "$(BUILD_DIR)/HVM.app" ]; then \
		echo "✗ $(BUILD_DIR)/HVM.app 不存在; 先 make build"; exit 1; \
	fi
	@if [ -e /Applications/HVM.app ]; then \
		echo "ℹ 覆盖旧版 /Applications/HVM.app"; \
		rm -rf /Applications/HVM.app; \
	fi
	cp -R $(BUILD_DIR)/HVM.app /Applications/HVM.app
	@LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"; \
		"$$LSREG" -f /Applications/HVM.app 2>/dev/null || true
	@echo "✔ 已安装: /Applications/HVM.app"

# 开发期 dev loop: 编译 + 安装 + 重启 GUI 主进程 (保留运行中的 VM host 子进程).
# 关键过滤: 主 GUI 进程 cmdline 只有一个 token (binary 路径), host 子进程
# 多个 (--host-mode-bundle ...). awk NF == 2 严格匹配只杀主 GUI, 不动 host.
# open .app 让 LaunchServices 起新 GUI; 老 host 子进程持有的 VM 继续运行.
run-app: install
	@OLDPID=$$(ps -axo pid,command | awk 'NF == 2 && $$2 ~ /MacOS\/HVM$$/ {print $$1}'); \
	if [ -n "$$OLDPID" ]; then \
		echo "ℹ 重启 GUI 主进程 pid=$$OLDPID (host 子进程不动)"; \
		kill $$OLDPID 2>/dev/null || true; \
		sleep 1; \
	fi
	@open /Applications/HVM.app
	@echo "✔ 已启动 /Applications/HVM.app"

# 从 /Applications/ 卸载 (用户数据 ~/Library/Application Support/HVM/ 不动)
uninstall:
	@if [ -e /Applications/HVM.app ]; then \
		rm -rf /Applications/HVM.app; \
		echo "✔ 已卸载 /Applications/HVM.app (用户数据 ~/Library/Application Support/HVM/ 保留)"; \
	else \
		echo "ℹ /Applications/HVM.app 不存在, 无需卸载"; \
	fi

# 让 Finder 立刻识别 .hvmz 为 package. 仅当 Finder 图标未更新时手动跑一次
register-types: build
	@LSREG="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"; \
	"$$LSREG" -f $(BUILD_DIR)/HVM.app; \
	killall Finder 2>/dev/null || true; \
	echo "✔ Launch Services 已刷新, Finder 已重启"

# 重置指定 VM 的运行时残留 + EFI nvram, 用于启动卡住时一键清理
# 用法: make reset-vm NAME=ubuntu24-m1
.PHONY: reset-vm
reset-vm:
	@test -n "$(NAME)" || { echo "用法: make reset-vm NAME=<vm-name>"; exit 1; }
	@BUNDLE="$$HOME/Library/Application Support/HVM/VMs/$(NAME).hvmz"; \
	test -d "$$BUNDLE" || { echo "✗ 未找到 $$BUNDLE"; exit 1; }; \
	pkill -9 -f "HVM.app/Contents/MacOS/HVM" 2>/dev/null || true; \
	sleep 1; \
	rm -f "$$BUNDLE/.lock"; \
	rm -f "$$BUNDLE/nvram/efi-vars.fd"; \
	rm -f "$$HOME/Library/Application Support/HVM/run/"*.sock 2>/dev/null || true; \
	echo "✔ 已重置 $(NAME) 的运行时残留 + EFI nvram"
