# TODO — 待办 / 路线图

> 进度元数据。每项链到设计稿。完成后挪到「已完成」或删。

## 待启动 (需用户输入)

- **开机 LOGO 自定义** — [docs/BOOT_LOGO_DESIGN.md](BOOT_LOGO_DESIGN.md)
  - 换 EDK2 固件内嵌 TianoCore BMP 为自定义图 (`MdeModulePkg/Logo/Logo.bmp` + 重 build)。
  - **阻塞**: D1 范围 (仅 Windows / 含 Linux) + D2 LOGO 图 (用户提供 PNG/BMP)。
  - 仅 Windows 改动小 (自建固件已在); Linux 需切自建固件评估。

## 候选 (未排期)

- **GUI 锁定态快照入口** — 加密 VM 锁定时也能做快照 (clonefile 不需密码; 当前 GUI 要先解锁)。见 [docs/SNAPSHOT_GUI_DESIGN.md](SNAPSHOT_GUI_DESIGN.md) §D4。
- **多窗口** — 进程内开多个 VM 画面独立窗口 (QemuFanoutSession 已支持 N subscriber, 缺开窗 UI 入口)。见 [docs/GUI.md](GUI.md)。
- **真·无头** — `-display none` + 解耦 AppKit。见 [docs/HEADLESS.md](HEADLESS.md) 路线图 P0–P4。

## 已完成 (近期)

- 新 GUI 创建向导 (业务页 #4) — [docs/CREATE_WIZARD_DESIGN.md](CREATE_WIZARD_DESIGN.md)
- 单一 tray 归属 (GUI/VMHost 接管与回退) — [docs/TRAY_OWNERSHIP_DESIGN.md](TRAY_OWNERSHIP_DESIGN.md)
- 快照接入 GUI + nvram/tpm 完整性修复 — [docs/SNAPSHOT_GUI_DESIGN.md](SNAPSHOT_GUI_DESIGN.md)
