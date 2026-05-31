# SNAPSHOT_GUI_DESIGN.md — 快照接入 GUI (创建 + 恢复) 设计稿

> 状态: **已落地** (2026-05-31). 实现: `SnapshotManager` 补 nvram/tpm clone (`cloneDirIfExists`/`restoreDirIfPresent`) + `HVMControl/VMControl+Snapshot.swift` + `NewGUIStore` 快照方法 + `GUI/Layout/DetailSnapshotSection.swift` + 接入 `DetailOverviewView`。CLI 回归 (nvram/tpm MODIFIED→ORIGINAL) + GUI e2e (create/restore/delete 经 hvm-dbg gui) 通过。回写 `STORAGE.md §5` / `GUI.md §7.2` / `CLAUDE.md`。

## 1. 目标 + 范围

把已有的 clonefile 快照 (`hvm-cli snapshot create/list/restore/delete`) 接进新 GUI 详情页。

### 做
- 详情页 `DetailSnapshotSection`: 列快照 (名 + 时间) + 创建 + 恢复 + 删除。
- 走 `VMControl.snapshot*` 单一来源 (新增 `VMControl+Snapshot.swift`), GUI store 包装。
- 破坏性操作 (恢复 / 删除) 走 `dialog.confirm(destructive:true)` (CLAUDE.md 硬约束)。
- 仅 VM **stopped** 可创建/恢复 (clonefile 要求盘不在写)。

### 不做 (越界)
- 不换快照机制 (clonefile 已是最省 + 最契合, 见 `docs/CREATE_WIZARD_DESIGN` 旁的讨论)。
- 不做在线快照 (HVF 无含 RAM 快照)。
- 加密 VM 锁定态的快照入口 v1 不单独做 (快照本身不需解密, 但详情页 section 统一 gating 在 `config != nil`; 锁定 VM 先解锁)。

## 2. 底层完整性修复 (随本期一起)

**问题**: `SnapshotManager.create/restore` 当前只 clone `disks/* + config(.enc)`, **漏了 `nvram/` (EFI vars/BootOrder) 和 `tpm/` (swtpm 状态)**。后果: 恢复磁盘但保留当前 nvram/tpm → Windows EFI 启动项错乱 / BitLocker (TPM 封印) 失效。注释第 5 行"复制 swtpm state"与代码不符。

**修复**: `create` 额外 clonefile 整个 `nvram/` + `tpm/` 子目录 (clonefile 支持目录递归 COW); `restore` 对称还原。**向后兼容**: 老快照无这两目录 → restore 跳过 (保留当前), 不报错。

## 3. 接口 / 文件

- `HVMControl/VMControl+Snapshot.swift` (新): `createSnapshot/listSnapshots/restoreSnapshot/deleteSnapshot`,
  内部 `assertStoppedIfNeeded` (create/restore 必停; list/delete 不要求) + 调 `SnapshotManager`。
  返回类型复用 `SnapshotManager.Info` (name/createdAt/path)。
- `NewGUIStore` (扩): `createSnapshot(_:name:)` / `snapshots(_:) -> [SnapshotManager.Info]` /
  `restoreSnapshot(_:name:)` / `deleteSnapshot(_:name:)`, 失败走 `lastError` + `refresh` (复用 `run`)。
  clonefile 秒级, 同步即可 (不 detached)。
- `app/Sources/HVM/GUI/Layout/DetailSnapshotSection.swift` (新): 详情页 section。
  - headerTrailing [创建快照] → `dialog.input` 收名 (校验交给 SnapshotManager) → `store.createSnapshot`
  - 列表行: 名 + 相对时间; 行尾 [恢复] (confirm destructive) / [删除] (confirm destructive)
  - `editable = runState == .stopped`; running 时 disabled + 文案 "停机后可操作"
- `DetailOverviewView`: 在 config 区插 `DetailSnapshotSection` (磁盘/启动之后, 加密之前)。

## 4. probeID

`detail.snapshot.create` / `detail.snapshot.restore-<name>` / `detail.snapshot.delete-<name>` /
确认 `detail.snapshot.confirm.restore-<name>` / `.confirm.delete-<name>` / 创建输入 `detail.snapshot.input.name`。

## 5. 风险 / 验证

- **P0 恢复破坏性**: 恢复覆盖当前 disks+config(+nvram/tpm), 必 confirm destructive; 必 stopped。
- **P0 nvram/tpm 修复回归**: 改 `SnapshotManager` 后, CLI `hvm-cli snapshot create/restore` 回归 (明文 + 含 nvram/tpm 的 VM)。
- **加密 VM**: clonefile 字节级, 创建/恢复不需密码; restore 后用源密码可解 (rekey 后须旧密码, 与 CLI 一致)。
- **e2e**: hvm-dbg gui 建 throwaway VM → 创建快照 → 改点东西 → 恢复 → 验证回退; CLI 侧 snapshot list 交叉确认。

## 6. 决策

| # | 议题 | 决策 |
|---|---|---|
| D1 | 快照机制 | APFS clonefile (维持, 不换) |
| D2 | GUI 操作集 | create + list + restore + delete |
| D3 | nvram/tpm 是否纳入快照 | **纳入** (修底层缺口, 向后兼容) |
| D4 | 加密锁定态入口 | v1 不单独做 (先解锁) |
| D5 | 恢复前自动存当前 | v1 不做 (仅 confirm); 后续可加 |
