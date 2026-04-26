# QEMU 补丁

本目录存放对 QEMU `v10.2.0` 上游源码的本地补丁, 由 `scripts/qemu-build.sh` 在构建前依次应用。

## 文件约定

- 补丁文件命名: `NNNN-short-subject.patch` (4 位数字前缀决定排序; 实际应用顺序以 `series` 为准)
- 每个 patch 由 `git format-patch` 产出, 必须包含:
  - `Subject:` — 一行简述, 中英文皆可
  - 正文 `Why:` 段 — 详细动机 (上游为何不收 / 项目特殊需求 / 关联 issue)
- 任一 patch `git apply --check` 失败 → `qemu-build.sh` 立即中断, **禁止 `--reject` / `--3way` 救场**
- 跨 QEMU 大版本升级时, 必须 rebase 全部补丁; 上游若已合并, 从 `series` 删除该行

## series 文件

每行一个补丁文件名, 按应用顺序排列。`#` 开头为注释, 空行忽略。

示例:

```
# 0001-fix-cocoa-fullscreen.patch
# 0002-virtio-gpu-arm64-cursor-bsod.patch
```

当前 `series` 为空 (尚无补丁); QEMU 源码以 `v10.2.0` 原样构建。

## 添加新补丁流程

1. 在 `build/qemu-src/` 内基于当前 `QEMU_TAG` 改代码 (`make qemu` 跑过后该目录就在)
2. `git -C build/qemu-src/ format-patch -1 HEAD` 产出 `0001-xxx.patch`
3. 拷到 `patches/qemu/`, 改名加 4 位前缀 (与 series 中下一个序号对齐)
4. 在 patch 正文加 `Why:` 段说明动机
5. 追加文件名到 `patches/qemu/series` 末行
6. `make qemu-clean && make qemu` 重新跑全流程, 验证 patch 干净 apply + 编译通过

## 不允许的做法

- ❌ fork 上游 QEMU 仓库改源码 (rebase 黑盒, 难审查)
- ❌ 在 `qemu-build.sh` 里直接写 `sed -i` 改源 (无 diff, 无 history)
- ❌ 用 `--ignore-whitespace` / `--reject` 强 apply 失败的补丁 (掩盖上游变化)
- ❌ 不写 `Why:` 段 (将来 rebase 时无法判断该补丁是否还有意义)
