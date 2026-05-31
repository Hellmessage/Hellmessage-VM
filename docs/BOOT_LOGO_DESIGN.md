# BOOT_LOGO_DESIGN.md — 开机 LOGO 自定义设计稿

> 状态: **待启动** (2026-05-31). 需先定 D1 范围 + 提供 LOGO 图。本稿先记录机制与方案,实现见 TODO。

## 1. 目标 + 范围

把 EDK2 固件开机时居中显示的 TianoCore LOGO 换成自定义图。

LOGO = EDK2 固件内嵌的 BMP (`MdeModulePkg/Logo/Logo.bmp`),`LogoDxe` 驱动经 Boot Logo Protocol 显示
(`ArmVirtPkg/ArmVirtQemu.dsc` 引入 `MdeModulePkg/Logo/LogoDxe.inf`)。"Start boot option" 文字是 BdsDxe
(ArmVirtPkg `PlatformBootManagerLib`) 另出,**不在本期范围** (改它要 patch 该 lib,且仅一闪而过)。

> ARM EDK2 **不支持** QEMU `-boot splash=` 那套 fw_cfg splash (x86 SeaBIOS 专属)。ARM 这边 LOGO 烤进固件,
> 唯一改法是替换内嵌 BMP + 重 build 固件。

## 2. 可行性 (按 guest 的固件来源)

| guest | 固件来源 | 可改 |
|---|---|---|
| **Windows** | HVM 自建 EDK2 (`scripts/edk2-build.sh` → `edk2-aarch64-code-win11.fd`, pflash) | ✅ 换 `Logo.bmp` 重 build |
| **Linux** | QEMU 自带 kraxel (`edk2-aarch64-code.fd`, `-bios`) | ❌ 上游烤死;要改须让 Linux 也用自建固件 (见 D1 选项 B) |

## 3. 实现方案

`edk2-build.sh` 每次 clone/reset 源码到干净态 → **手动改 `Logo.bmp` 会被冲掉**,必须在构建流程注入:

1. 自定义图入仓库: `app/Resources/boot-logo.bmp` (随仓库分发,GPL 无关,自家素材)。
2. `edk2-build.sh` 在 clone/reset 后、`build` 前加一步:
   `[[ -f <repo>/app/Resources/boot-logo.bmp ]] && cp ... MdeModulePkg/Logo/Logo.bmp`
   (文件不存在则保持默认 TianoCore,不破坏无图构建)。
3. `make edk2` (重编固件) → `make qemu` (重打进 `edk2-aarch64-code-win11.fd`) → `make install`。
4. MANIFEST 记一笔"LOGO 已替换"以便溯源 (可选)。

### BMP 规格 (EDK2 `BmpSupportLib` / `TranslateBmpToGopBlt` 限制)
- **未压缩 (BI_RGB)、24-bit** 最稳 (1/4/8/24 支持,**禁压缩 / 32-bit alpha**)。
- 尺寸适中 (原图 ~250×115;大图居中显示,别超 guest framebuffer 默认分辨率)。
- 提供 PNG 等任意格式时,打包者侧 `sips`/`ffmpeg` 转 24-bit BMP 入库。

## 4. 风险 / 验证
- **P0 BMP 不合规 → LogoDxe 不显示或固件起不来**: 严格 24-bit 未压缩;build 后 `hvm-dbg screenshot` 验证开机帧。
- 只影响 Windows 固件;Linux 不变 (除非 D1 选 B)。
- 重 build EDK2 是打包者成本 (~700MB clone + cross compile),最终用户无感 (随 .app 分发)。

## 5. 决策 (待定)

| # | 议题 | 选项 | 默认 |
|---|---|---|---|
| D1 | 范围 | A=仅 Windows / B=Linux+Windows (Linux 切自建固件,需评估 kraxel→自建 对 Linux 启动影响) | **待用户定** |
| D2 | LOGO 图 | 用户提供 (PNG/BMP) | **待用户提供** |
| D3 | 是否一并改 "Start boot option" 文字 | 否 (本期不动) | 否 |
