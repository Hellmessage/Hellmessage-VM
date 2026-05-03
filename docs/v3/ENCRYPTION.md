# VM 整盘加密 (`HVMEncryption`)

> 状态: **设计稿 (2026-05-04)**, 未进入实现。本稿目标是把"VMware Workstation/Fusion 风格的整 VM 加密"在 HVM 上落成方案,等评审通过再拆 PR。

## 目标

- **整 VM 加密**: 不只是磁盘,而是 disks + config.yaml + nvram + tpm + auxiliary + bundle 内 console log,一并加密
- **per-VM 密钥**: 每台 VM 一把独立 KEK,泄露一台不波及其他
- **macOS 原生路径**: 走 hdiutil sparsebundle + Keychain (Touch ID),不引第三方加密库,不写自家 crypto
- **VZ + QEMU 双后端透明**: VZ 必走 raw,QEMU 走 qcow2,加密层都在文件系统下方,后端无感
- **不破坏现有 bundle 语义**: 解锁后挂载点目录布局与现状 1:1,业务代码读写路径几乎无改动
- **可逆**: 用户可把已加密 VM 转回明文,反之亦然(冷迁移,不在线)
- **改密无重密**: 改 KEK 不重密 DEK,秒级完成
- **忘密不可恢复**: 对齐 VMware,不留 master key / 后门

## VMware 模型对照

VMware Workstation/Fusion 加密模型(参考):

| 模块 | VMware | HVM 对照 |
|---|---|---|
| 加密对象 | `.vmx` / `.vmdk` / `.nvram` / `.vmem` / `.vmss` / 快照 | `config.yaml` / `disks/*` / `nvram/*` / `tpm/*` / `auxiliary/*` / bundle 内 `logs/console-*.log` / `snapshots/*` |
| 数据密钥 (DEK) | AES-256, 包于 vmx | AES-256-XTS, 由 sparsebundle 内部 keybag 管 |
| 密钥包 (KEK) | 用户密码 / KMS / vCenter | 用户密码 / Keychain 随机 KEK (Touch ID) |
| 解锁时机 | power-on 输密码 | start VM 时 attach sparsebundle |
| 改密 | 不重密 DEK | `hdiutil chpass`(同语义) |
| 限制 | 加密 VM 不能 PXE / 部分 USB 限制 | 见下「能力边界」 |
| 不可恢复 | 是 | 是 |

HVM 不实现:多租户 / KMS / vCenter 风格 key server / 加密快照单独密钥。单机产品场景,当前不需要。

## 路线选型

| 方案 | 加密范围 | VZ 兼容 | 改动量 | 选用 |
|---|---|---|---|---|
| **A. sparsebundle 套整 bundle** | 整 VM | ✅ 透明 | 中 | ✅ |
| B. qcow2 内置 LUKS | 仅 disks | ❌(VZ raw 不支持) | 小 | ✗ — 仅 QEMU 受益,与 VZ 后端不对称 |
| C. APFS 加密卷 / FileVault 子卷 | 全部(全有/全无) | ✅ | 0 | ✗ — 不是 per-VM,无法 per-VM 改密 / per-VM 迁移 |

**选 A**。理由:加密粒度 per-VM,Apple 原生路径,VZ + QEMU 都透明,与"整 VM 加密"语义最贴。

## Bundle 结构变化

### 明文 VM (现状,不变)

```
~/Library/Application Support/HVM/VMs/Foo.hvmz/
├── config.yaml
├── disks/
├── nvram/
└── ...
```

### 加密 VM (新增形态)

```
# 真实落盘形态
~/Library/Application Support/HVM/VMs/Foo.hvmz.sparsebundle/
├── Info.plist
├── token                    — KEK 解 DEK 的 keybag(由 hdiutil 维护)
└── bands/
    └── ...                  — 分块加密数据 (默认 8 MiB / band)

# attach 后挂载点 (运行期临时存在)
~/Library/Application Support/HVM/mounts/<uuid8>/
└── Foo.hvmz/                — 与现状 1:1, 业务代码无感
    ├── config.yaml
    ├── disks/os.img | os.qcow2
    ├── nvram/efi-vars.fd
    ├── tpm/
    ├── auxiliary/
    ├── snapshots/
    ├── logs/console-*.log
    └── .lock
```

判定一个 VM 是否加密:看 `~/Library/.../VMs/` 下面是 `Foo.hvmz/`(目录 = 明文)还是 `Foo.hvmz.sparsebundle/`(目录 = 加密容器)。两种形态可同卷共存。

挂载点路径用 `<uuid8>` 而非 `<displayName>`,避免中文 / 特殊字符 / 同名 VM 冲突。

## 密钥管理

### 双层密钥(对齐 VMware DEK / KEK)

- **DEK** (Data Encryption Key, AES-256-XTS)
  - sparsebundle 创建时由 hdiutil 内部随机生成
  - 永远不出 sparsebundle,HVM 进程**不持有**
  - 实际加密 / 解密由 macOS DiskImages 框架在 VFS 层完成
- **KEK** (Key Encryption Key)
  - 用户密码或随机 32 字节,经 hdiutil 内部 PBKDF2 派生后用于解 token 中的 DEK
  - 两种来源由用户在创建时选定:

| `kek_source` | KEK 来源 | 启动体验 | 风险 |
|---|---|---|---|
| `password` | 每次启动手输 | 每次弹框输密码 | 输错锁定;密码丢失不可恢复 |
| `keychain` | 随机 KEK 存 Keychain,`kSecAttrAccessControl = userPresence` | Touch ID / 系统密码确认 | 设备丢失不会泄密(Keychain 由 Secure Enclave 守);用户被胁迫场景仍会泄密 |

`keychain` 模式下,Keychain item 名:`com.hellmessage.vm.kek.<uuid>`,access group 默认沿用 app bundle ID。

### 改密(rekey)

`hdiutil chpass <sparsebundle>` — 仅换 KEK,不重密底层 DEK,几毫秒完成。

`keychain` 模式改密:删旧 Keychain item → 生成新随机 KEK → 调 `hdiutil chpass` → 写新 Keychain item。失败则回滚(老 KEK 仍可用)。

### 忘密 / 失锁

- `password` 模式:无密码 = 无法启动 = 数据永久不可读。**对齐 VMware**,不留后门。
- `keychain` 模式:用户主动删了 Keychain item 等价于忘密。建议用户开启加密时**同时**导出一份恢复密码到外部密码管理器(GUI 提示)。

## config.yaml schema 变化

### 新顶层字段(schema v3)

```yaml
schemaVersion: 3
encryption:
  enabled: true
  scheme: sparsebundle-aes256       # 当前唯一值
  kek_source: keychain              # password | keychain
  keychain_item: com.hellmessage.vm.kek.<uuid>   # 仅 keychain 模式
  bands_band_size_mb: 8             # sparsebundle band 大小, 影响 sparse 颗粒
  created_at: 2026-05-04T...
  cipher_advertised: AES-256-XTS    # 仅信息性, 实际由 sparsebundle 决定
```

明文 VM 的 `encryption` 字段缺省 / `enabled: false`。

注意:`config.yaml` 在挂载点内,本身被 sparsebundle 加密。**外层只能看到 sparsebundle 容器本身**,看不到 config 内容,也就读不到 `encryption.kek_source` — 这是问题。

→ 解决:在 sparsebundle **同级目录**写一份 `Foo.hvmz.encryption.json`(明文,只放 routing 信息):

```json
{
  "schemaVersion": 1,
  "vm_id": "<uuid>",
  "kek_source": "keychain",
  "keychain_item": "com.hellmessage.vm.kek.<uuid>",
  "display_name": "Foo"
}
```

GUI 列表 / `hvm-cli list` 不挂载就能看到 VM 存在 + 是加密的 + 哪个 keychain item。这份 routing 文件**不含**任何密码 / DEK / 可解密信息。

### ConfigMigrator

v2 → v3:`encryption` 缺省塞 `enabled: false` 即升完。无破坏性变更。

## 生命周期

### 创建加密 VM

```
1. 用户在 GUI 向导勾 "加密整个虚拟机" + 选 KEK 源 (+ 输密码)
2. hvm-cli create / GUI 走 EncryptedBundleIO.create:
   a. hdiutil create -encryption AES-256 \
        -size <NumGiB>g \                    ← 容器上限, 见下
        -fs APFS \
        -volname HVM-<uuid8> \
        -type SPARSEBUNDLE \
        -stdinpass \
        ~/Library/Application Support/HVM/VMs/<name>.hvmz.sparsebundle
   b. hdiutil attach -nobrowse -mountpoint <mountpoint> -stdinpass
   c. 在挂载点内走原 BundleIO.create 逻辑 (写 config.yaml / 建 disks/ etc.)
   d. 在 sparsebundle 同级写 .encryption.json routing 文件
   e. keychain 模式: 把 KEK 存 Keychain
   f. detach (除非紧接着启动)
```

**容器大小如何定**:sparsebundle 是稀疏的,实际占用按写入数据增长,但**容器上限**必须创建时定。策略:`bundle_max_gib = sum(disks.sizeGiB) + 32 GiB 余量`,允许后续 grow(`hdiutil resize`)。

### 启动加密 VM

```
1. VMHost / hvm-cli start <name>:
   a. 检测 .hvmz.sparsebundle 形态 → 走加密通路
   b. 读 sibling .encryption.json → 拿 kek_source / keychain_item
   c. 拉 KEK:
      - keychain → SecItemCopyMatching (会触发 Touch ID)
      - password → GUI 弹密码框 / CLI 走 getpass
   d. hdiutil attach -nobrowse -mountpoint <mountpoint> -stdinpass
   e. 走原 BundleIO.load(mountpoint/<name>.hvmz)
   f. 走原 flock + engine 启动路径
```

挂载点为 `~/Library/Application Support/HVM/mounts/<uuid8>/`,启动前确保该目录存在且空闲。若有 stale mount(上次 crash 没 detach),先 force detach 再重挂。

### 停止加密 VM

```
1. engine 进程退出
2. flock 释放
3. hdiutil detach <mountpoint>  ← 必须成功, 否则 VM 数据可能未刷盘
4. 若 detach 失败 → 重试 hdiutil detach -force, 仍失败则告警 + 写 host log
```

`-force` 不是首选,因为可能丢未刷的写。仅在 normal detach 失败时降级。

### 删除加密 VM

```
1. 确认 VM 已停 + 已 detach
2. rm -rf <name>.hvmz.sparsebundle + <name>.hvmz.encryption.json
3. keychain 模式: 删 Keychain item
4. host log 子目录 (~/Library/.../logs/<displayName>-<uuid8>/) 跟现状一样不动
```

### 改密 / 切换 KEK 源

- `password → password`: `hdiutil chpass`,仅换密码
- `password → keychain`: 生成随机 KEK → `hdiutil chpass`(把容器密码改成新 KEK)→ 存 Keychain → 改 routing JSON
- `keychain → password`: 反向同上,删 Keychain item
- `keychain → keychain`: 旋转一遍即可(几乎用不到)

CLI: `hvm-cli rekey <vm> [--source password|keychain]`

### Clone / Snapshot

#### Snapshot(bundle 内 snapshot)

`snapshots/` 在 sparsebundle 内,走原 `SnapshotManager.create` 即可,clonefile 在 sparsebundle 内的 APFS 子卷上仍然有效。**无需为 snapshot 引入二级 KEK** — 整个 sparsebundle 一把 KEK 即可。

#### Clone 整个 VM(跨 bundle)

- **冷克隆**:`cp -R <source>.sparsebundle <target>.sparsebundle` + 提示用户 `chpass` 换新 KEK(否则两台共密)
- **导出迁移**:复制 sparsebundle 到目标机器,目标机器输密码 attach 即用。Keychain item 不跨机器迁移(这是 feature,目标机器需重新建立 Keychain 信任)

### 加密化 / 去加密化(冷迁移)

- `hvm-cli encrypt <vm>`:VM 已停 → 创建新 sparsebundle → cp 内容进去 → 删旧目录
- `hvm-cli decrypt <vm>`:VM 已停 → 创建空目录 → cp 内容出来 → detach + 删 sparsebundle

二者都需要 1× bundle 大小的临时空间;主盘大时(几十 GB)耗时分钟级,GUI 走进度条。

## CLI / GUI 接口

### CLI 新增

```
hvm-cli create --encrypt [--kek-source password|keychain] ...
hvm-cli encrypt <vm> [--kek-source ...]
hvm-cli decrypt <vm>
hvm-cli rekey <vm> [--kek-source ...]
hvm-cli encrypt-status <vm>           # 输出加密元信息
```

`hvm-cli list` 区分明文 / 加密两种形态(不挂载,读 sibling routing JSON)。

### GUI 新增

- 创建向导:加 "加密整个虚拟机" 复选框 + KEK 源选择(`HVMFormSelect`)+ 密码输入(`HVMTextField` secure 模式)
- VM 详情页:新增 "加密" 区,展示状态 + "改密"/"移除加密"/"加密(明文 VM)"按钮
- 启动时:`password` 模式弹 `HVMModal` + 密码框,**无遮罩点击关闭**(沿用现有约束),只能取消(中止启动)或确认
- 错误:KEK 解锁失败走 `ErrorDialog`,中文提示 "密码错误,请重试" / "Touch ID 取消" / "Keychain 项目缺失"

### 约束遵循(CLAUDE.md)

- 密码框走 `HVMTextField`(需扩 secure 模式,放 `app/Sources/HVM/UI/Style/HVMX.swift`,不散落)
- KEK 源选择走 `HVMFormSelect`
- 弹窗走 `HVMModal`,X 按钮关闭
- 错误走 `ErrorDialog`,不用 `NSAlert`
- 日志走 `HVMPaths.vmLogsDir(...)`,**不**写到 `<bundle>/logs/`(因为加密的 bundle 在 detach 后写不进去,且 host 侧问题排查也需要不挂载就能看到)

## 与 VZ / QEMU 后端的交互

### 文件路径

启动时所有 disk / nvram / aux 路径都基于 mountpoint 拼,例:

```
disk.path = "disks/os.img"        # config 里仍是相对路径, 不变
absolute  = <mountpoint>/Foo.hvmz/disks/os.img
```

`VMConfig.mainDiskURL(in:)` 等 helper 已经按"传入 bundle URL"工作,把 bundleURL 从 `~/.../VMs/Foo.hvmz` 替成 `<mountpoint>/Foo.hvmz` 即可。

### VZ 后端

- `VZDiskImageStorageDeviceAttachment` 接受任意可读写路径,挂载点内 raw `.img` 完全 OK
- entitlement: `com.apple.security.virtualization` 不限制访问自家挂载的 sparsebundle
- 风险: VZ 进程的 sandbox / TCC 是否拦截?**需实测**(测试项 T1)

### QEMU 后端

- QEMU `Process` 启动,argv 里磁盘路径用挂载点绝对路径
- QMP socket 仍走 `~/Library/.../run/<uuid>.qmp`(**不在 sparsebundle 内**),因为 sparsebundle umount 后 socket 也消失,而 run/ 是跨进程 IPC 入口
- 风险: QEMU 跑 hvf,sandbox 是否拦截读写挂载点?**需实测**(测试项 T1)

### swtpm / EDK2 firmware

- swtpm state 走 `<mountpoint>/Foo.hvmz/tpm/`(加密)
- EDK2 firmware 来自 `Bundle.main/Resources/QEMU/share/qemu/`(明文资源,与加密无关)
- swtpm `--ctrl --server` socket 走 `~/Library/.../run/<uuid>.swtpm.*`(同 QMP,在 run/)

## 异常处理

### 启动期

| 失败点 | 处理 |
|---|---|
| Keychain 拉 KEK 取消(用户取消 Touch ID) | 中止启动,不重试 |
| Keychain item 不存在 | 降级到密码框 + 提示 "Keychain 项目缺失,请输入密码恢复" |
| `hdiutil attach` 失败(密码错) | 提示重试,3 次失败后中止 |
| `hdiutil attach` 失败(stale mount) | 自动 force detach 同 uuid8 mountpoint 再重试 1 次 |
| 挂载成功但 `flock` 失败 | 报"VM 已在另一进程运行",detach 后退出 |
| engine 启动失败 | 走原错误流程,**注意**: detach 必须执行(放 `defer`) |

### 运行期

| 事件 | 处理 |
|---|---|
| host crash / panic / kill -9 | sparsebundle stale mount,下次启动检测并 force detach 后重挂 |
| 主机休眠 / 锁屏 | sparsebundle 不会自动 detach;Keychain `userPresence` 受系统策略影响,但已挂载状态不需要再次解锁 |
| FileVault 关 / 用户登出 | sparsebundle 跟登录会话绑,登出会强制 detach;VM 进程随之被 SIGTERM |
| 容器空间不足(写满) | sparsebundle 容器达上限 → APFS 子卷写失败 → guest 报 I/O error。host 侧检测到挂载点剩余空间低 < 1 GiB 时弹 banner 提示 grow 容器 |

### 启动期清理 stale mount

`HVMPaths.runDir/mounts.json`(host 侧维护)记录每次成功 attach 的 `<sparsebundle path, mountpoint, vm uuid>`。HVM 主进程启动 / VMHost 启动前扫一遍:

- 如果 mountpoint 仍挂着但 vm uuid 对应进程不存在 → force detach + 清记录
- 如果 mountpoint 不存在但记录还在 → 清记录

避免 sparsebundle 被永久占用导致下一次启动失败。

## 不做什么

1. **不实现自家 crypto**: 全交给 macOS DiskImages / Keychain / Secure Enclave
2. **不支持加密快照单独密钥**: 一把 KEK 管整 sparsebundle,snapshots 在内部
3. **不实现 KMS / vCenter 风格 key server**: 单机产品场景不需要
4. **不加密共享资源**: IPSW / virtio-win driver / OS image cache 一律明文(在 `~/Library/.../HVM/cache/`)
5. **不加密 host 侧 log**(`~/Library/Application Support/HVM/logs/...`): 与 FileVault 对齐,host log 是排查问题用的,加密反而妨碍调试
6. **不加密 socket / run 目录**(`~/Library/.../HVM/run/<uuid>.*`): IPC / QMP / HDP / vdagent / swtpm socket 一律明文,生命周期短,内容不持久化
7. **不加密 launchd plist**: socket_vmnet 等系统级 plist 与 VM 无关
8. **不做 TPM-bound KEK**: macOS 没有 TPM,Secure Enclave 由 Keychain 替代
9. **不做"配置改写需密码"**: VMware 那种 restriction 留作 v4 再议
10. **不做在线加密化 / 去加密化**: 必须冷迁移
11. **不实现密码强度校验 / 复杂度规则**: 提示用户而已,不强制
12. **不实现密码恢复**: 忘了就忘了

## 风险与待验证项 (Testing Plan)

| 编号 | 项目 | 优先级 | 验证方法 |
|---|---|---|---|
| T1 | VZ + QEMU 进程的 sandbox / TCC 能否读写自家挂载的 sparsebundle | **P0** | 写最小 PoC: `hdiutil attach` 一个测试 sparsebundle,放一个 raw .img,用 VZ 跑 Linux,看是否能正常 boot;同样跑 QEMU |
| T2 | sparsebundle band 大小对 VM I/O 性能影响 | P1 | 4 / 8 / 16 / 32 MiB band,fio 顺序 + 随机 4K,对比 |
| T3 | 加密层 AES-NI 实测 overhead | P1 | 与明文 VM 对照,iperf-like guest 内 dd / fio,Apple Silicon |
| T4 | host crash 后 stale mount 清理是否可靠 | **P0** | kill -9 主进程,模拟 panic,看下次启动能否 force detach 并重挂 |
| T5 | Keychain `userPresence` 在 SSH / 远程登录场景是否退化为密码框 | P1 | 实测 ssh + Touch ID 不可用时的 fallback |
| T6 | 大 sparsebundle (100 GB+) clone / chpass / detach 时延 | P1 | 实测耗时,GUI 进度条阈值定 |
| T7 | sparsebundle 跨 macOS 大版本兼容 (Sonoma / Sequoia / Tahoe) | P1 | 三版本 attach 同一 sparsebundle |
| T8 | Time Machine / iCloud 备份 sparsebundle 行为 | P2 | 看是否按 band 增量,是否上 iCloud(不期望) |
| T9 | 关 FileVault 时加密 VM 是否仍能用 | P2 | sparsebundle 加密独立于 FileVault,理应可以,但实测确认 |

T1 / T4 是 **must pass** 才进入实现;其他在 PR 拆解阶段验证。

## 落地拆解 (PR 切分)

按"小步可回滚"原则,8 个 PR,顺序串行:

| PR | 内容 | 时间盒 |
|---|---|---|
| **PR-1** | 工具层: `HVMEncryption/SparsebundleTool.swift` 包 hdiutil create/attach/detach/chpass + 单测(用 6 MiB 测试 sparsebundle) | 1 天 |
| **PR-2** | `HVMEncryption/KeychainKEK.swift` 封装 SecItem read/write/delete + Touch ID 触发 + 单测(可跳过 Touch ID 用 mock) | 1 天 |
| **PR-3** | `EncryptedBundleIO`: create / load / save / delete 与 `BundleIO` 共享接口 + sibling routing JSON 读写 + ConfigMigrator v2→v3 | 2 天 |
| **PR-4** | `HVMPaths.mountpointFor(uuid:)` + stale mount 清理 (`MountReaper`) + 启动时 reaping | 1 天 |
| **PR-5** | `VMHost` / engine 启动路径接入: detect → attach → run → defer detach + T1 / T4 实测 | 2 天 |
| **PR-6** | `hvm-cli encrypt / decrypt / rekey / encrypt-status` 子命令 + e2e 测试 | 2 天 |
| **PR-7** | GUI 创建向导 + 详情页加密区 + 密码 modal(`HVMTextField` secure 模式扩展) | 3 天 |
| **PR-8** | 文档同步: 把本稿合入 `docs/v1/`,更新 `CLAUDE.md` 加密约束节,更新 `STORAGE.md` / `VM_BUNDLE.md` 引用 | 0.5 天 |

合计 ~12.5 天 / 1 人。可在 PR-1/PR-2 并行,PR-4/PR-5 之后才接 PR-6/PR-7。

每个 PR 必须 `make build` 通过,**禁止 squash 跨 PR 合并** — 每个 PR 都是独立可 revert 的小步。

## 未决事项

| 编号 | 问题 | 当前默认 | 决策时机 |
|---|---|---|---|
| D1 | 加密 VM 的 host 侧 console log 是否也加密? | 不加密 (留排查用) | 本稿前可定 |
| D2 | 是否允许"明文 + 加密"两种 VM 同时存在,还是全局开关? | 允许共存 | 已决 |
| D3 | sparsebundle band 大小默认值 | 8 MiB(待 T2) | T2 完成后 |
| D4 | 容器初始上限策略(disks 总和 + 多少余量) | `+ 32 GiB`(可 grow) | 本稿前可定 |
| D5 | `keychain` 模式是否要求**同时**设一个回退密码? | 是,创建时双轨;Keychain 失效后用回退密码 | 待决 — 若是,简化"Keychain 损坏"边界,但 UI 多一步 |
| D6 | 是否支持"加密 VM"下层放在外置 NVMe / U 盘? | 支持(sparsebundle 与卷无关) | 已决 |
| D7 | Mac Studio / Mac mini 无 Touch ID 设备的 keychain 模式体验 | 退到系统密码 prompt | 已决 |
| D8 | 加密 VM 的迁移工具(导出 / 导入到另一台 Mac) | `hvm-cli export <vm> --bundle.tar` 直接复制 sparsebundle 文件即可,无额外工具 | 已决 |

## 相关文档

- [VM_BUNDLE.md](../v1/VM_BUNDLE.md) — 现状 bundle 布局 / config schema v2
- [STORAGE.md](../v1/STORAGE.md) — 磁盘格式与 DiskFactory(本稿不改)
- [VZ_BACKEND.md](../v1/VZ_BACKEND.md) — VZ entitlement / disk attachment
- [QEMU_INTEGRATION.md](../v1/QEMU_INTEGRATION.md) — QEMU 进程模型 / argv 路径
- [ENTITLEMENT.md](../v1/ENTITLEMENT.md) — 现有 entitlement 清单(本稿不增 entitlement)
- [../../CLAUDE.md](../../CLAUDE.md) — 全局约束(本稿落地后需新增"加密约束"节)

---

**最后更新**: 2026-05-04
**状态**: 设计稿,等评审 / T1 / T4 PoC 通过后启动 PR-1
