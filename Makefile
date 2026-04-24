# HVM Makefile
# 唯一构建入口 (Xcode 打开 Package.swift 作为开发期辅助, 不做权威构建)

CONFIGURATION ?= release
BUILD_DIR     := build
SWIFTPM_DIR   := .build
# 签名身份: 空/auto = bundle.sh 自动探测 (Apple Development 优先, 否则 ad-hoc)
SIGN_IDENTITY ?= auto
ENTITLEMENTS  := Resources/HVM.entitlements

.PHONY: all build bundle compile dev test verify clean help icon register-types

# 默认: release 模式 + 完整 .app 签名
all: build

build: bundle

help:
	@echo "HVM 构建命令:"
	@echo "  make build   — release 模式, 组装 .app + 签名 (默认)"
	@echo "  make dev     — debug 模式, 组装 .app + 签名"
	@echo "  make test    — 跑 swift test"
	@echo "  make verify  — smoke test, 验证 .app 可启动"
	@echo "  make icon    — 从 Resources/AppIcon-src.png 生成 AppIcon.icns"
	@echo "  make clean   — 清除 build/ 和 .build/"

# 1. SwiftPM 编译全部 executable
compile:
	swift build -c $(CONFIGURATION) --product HVM
	swift build -c $(CONFIGURATION) --product hvm-cli
	swift build -c $(CONFIGURATION) --product hvm-dbg

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
	swift test

verify:
	@bash scripts/verify-build.sh

clean:
	rm -rf $(BUILD_DIR) $(SWIFTPM_DIR)
	@echo "✔ 已清除 build/ 与 .build/"

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
