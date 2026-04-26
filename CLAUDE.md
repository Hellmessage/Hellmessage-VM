# CLAUDE.md

本项目走 Apple Virtualization.framework 路线。

## 文档约束

- `CLAUDE.md` 只存放约束, 不放其他东西
- `README.md` 存放项目说明(开发完成后再写)
- `docs/` 下的设计文档是决策沉淀, 约束变更必须同步更新

## 身份与命名约束 **必须遵守**

- App bundle ID: `com.hellmessage.vm`(已在 Apple Developer 注册, Team ID `Q7L455FS97`)
- App 显示名: `HVM`, 产物 `HVM.app`
- CLI 工具: `hvm-cli`
- 调试探针: `hvm-dbg`
- VM bundle 扩展名: `.hvmz`(与 hell-vm 的 `.hellvm` 区分, 两项目 bundle 可共存于同一目录不冲突)
- 用户数据根: `~/Library/Application Support/HVM/`(VMs/ + cache/ + logs/)

## 交付约束 **必须遵守**

- 代码变更后必须 `make build` 验证
- `make build` 通过才算任务完成, 否则视为未完成
- 空白 Mac 上 `make build` 一条命令跑通, 除 Xcode Command Line Tools 和 Apple Developer 证书外**零手动依赖**
- 不引入 Homebrew / Vendor / 编译外部 C 项目等重依赖, 所有逻辑走 Swift + Apple framework

## 构建约束

- 所有构建产物输出到根目录 `build/`(`build/HVM.app`, `build/hvm-cli`, `build/hvm-dbg`)
- SwiftPM 是唯一构建系统, 产物由 `scripts/bundle.sh` 组装 + 签名成 `.app`
- 同时兼容 Xcode: `xed app/Package.swift` 可直接打开、编辑、构建(产裸二进制, 无 entitlement, 仅用于开发期调试)
- 真实运行必须走 `make build`(出带 entitlement 签名的 .app)

## 代码约束

- 代码文件使用中文注释
- 模块命名前缀 `HVM`(与主 App target 同名)
- SwiftPM 6 tools-version, 目标 platform macOS 14+
- 仅依赖官方 framework + swift-argument-parser, **不引其他三方包**

## 签名与 Entitlement 约束

- 必须的 entitlement: `com.apple.security.virtualization`(Apple Developer 账号自带, 不用申请)
- 签名方式: 自动 `codesign --sign "Apple Development"` ad-hoc 签名, 不公证不分发
- 桥接网络 (`com.apple.vm.networking`) 已向 Apple 提交申请, 审批中。批准前**只实现 NAT 网络**, 审批后再加 `.bridged` case
- 签名相关代码或日志**不得输出任何 team ID / 证书 SHA / 私钥路径**

## GUI 约束

- 黑色风格界面
- **弹窗只能通过点击右上角 X 按钮关闭**, 禁止点击遮罩层关闭
- 所有错误对话框走统一 ErrorDialog, 禁止用 `NSAlert`
- 主窗口默认深色, 不跟随系统主题

## VZ 能力边界约束 **必须遵守**

以下能力 **VZ 不支持**, 即使用户要求也不得尝试实现, 直接提示用户能力边界:

- **x86_64 / riscv64 guest** — VZ 只支持原生 arm64, 无 TCG 翻译
- **Windows guest** — VZ 无 TPM 给 Windows, Win11 无法装。Win10 ARM 虽能启动但 Apple 已停供 ISO。**不实现 Windows 支持**, 向导里不出现 Windows 选项
- **host USB 设备直通** — VZ API 不支持 `usb-host` 类语义, 只支持虚拟 USB mass storage。若用户要求插 U 盘直通, 明确告知做不到, 建议 `dd` 成 image 再 `VZUSBMassStorageDevice` 挂载
- **多 VM 共享同一 bundle** — 一个 `.hvmz` 同时只能被一个进程打开, 用 fcntl flock 互斥
- **热插拔 CPU/内存** — VZ 不支持运行时改 CPU/mem 数量, 必须停机重配

## 支持的 Guest OS 约束

- **macOS** — Apple Silicon only, 通过 IPSW + `VZMacOSInstaller` 装机
- **Linux** — arm64 ISO 启动安装, 装完切 `bootFromDiskOnly` 直走硬盘
- **其他** — 不支持, 配置不允许保存其他 `GuestOSType`

## 调试/诊断工作方式约束 **必须遵守**

- **禁止使用 osascript / AppleScript UI scripting 模拟 GUI 点击**(脆弱、依赖屏幕坐标和辅助功能权限, 不可复现)
- 需要启动/停止 VM 走 `hvm-cli` 或 `hvm-dbg`, 不靠 HVM GUI
- 需要在 guest 内做操作(看桌面、点按钮、键入命令)走 `hvm-dbg` 子命令
- `hvm-dbg` 扩展原则: 零新协议实现, 只复用已暴露的公开 VZ API 封装
- 遇到能力缺失**立即扩展 `hvm-dbg`**, 不要退回用 osascript

## 磁盘与存储约束

- 磁盘格式固定 **raw sparse file**(macOS APFS 天然 sparse, 不需要 qcow2)
- 主盘文件名: `<bundle>/disks/main.img`
- 数据盘文件名: `<bundle>/disks/data-<uuid 前 8 字符>.img`
- ISO 路径**不复制进 bundle**, 只存绝对路径
- 磁盘扩容走 `truncate` + guest 内 `resize2fs` / 分区工具, host 侧只改文件大小

## 提交信息约束

- 格式: `type(scope): 中文描述 [English summary]`
- type 取值: `feat` / `fix` / `refactor` / `docs` / `chore` / `test`
- scope 取值: 模块名小写(`core` / `bundle` / `storage` / `backend` / `display` / `app` / `cli` / `probe`)
- 每次 commit 前必须 `make build` 通过
