// HVMEncryption/EncryptionKDF.swift
// 从 master KEK 派生 4 个 32 字节子 key. HKDF-SHA256, info 字符串当版本.
// 设计稿 docs/v3/ENCRYPTION.md v2.2 "密钥管理 三层密钥".
//
// 流程 (启动加密 QEMU VM 时):
//   master_KEK = PasswordKDF.deriveMasterKey(password, salt, iter)   // 32 字节
//   sub_keys   = EncryptionKDF.deriveAll(masterKey: master_KEK)
//        ├─ qcow2-disk-key  (32B) → -object secret 注入 qemu-img / qemu-system
//        ├─ qcow2-nvram-key (32B) → 同上, OVMF VARS LUKS qcow2
//        ├─ swtpm-key       (32B) → swtpm --key fd= 透传
//        └─ config-key      (32B) → AES.GCM.SealedBox(config.yaml)
//
// 不用 salt:
//   master_KEK 已经是 PBKDF2(password, 16-byte random salt) 派生 — 自带高熵.
//   HKDF salt 留空, info 字符串区分子 key 的"用途上下文".
//
// info 字符串当版本:
//   未来加新加密点 (例: backup-key) 时直接加新 SubKeyKind, info 字符串唯一不冲突.
//   不会"破坏"老 VM (它只用 4 个老子 key, 新子 key 派生与否不影响).

import Foundation
import CryptoKit
import HVMCore

public enum EncryptionKDF {
    /// 子 key 标签 (HKDF info 字符串). rawValue 是稳定字符串, 不可修改 — 改了等于换 key, 老 VM 解不开.
    public enum SubKeyKind: String, Sendable, CaseIterable {
        case qcow2Disk  = "qcow2-disk"
        case qcow2Nvram = "qcow2-nvram"
        case swtpm      = "swtpm"
        case config     = "config"
    }

    /// 4 个子 key 的捆绑结构. deriveAll 一次返回全部, 调用方按需取.
    public struct SubKeySet: Sendable {
        public let qcow2Disk:  SymmetricKey
        public let qcow2Nvram: SymmetricKey
        public let swtpm:      SymmetricKey
        public let config:     SymmetricKey

        public func key(for kind: SubKeyKind) -> SymmetricKey {
            switch kind {
            case .qcow2Disk:  return qcow2Disk
            case .qcow2Nvram: return qcow2Nvram
            case .swtpm:      return swtpm
            case .config:     return config
            }
        }
    }

    /// 派生单个子 key.
    /// HKDF<SHA256>(IKM=master, salt=<empty>, info=kind.rawValue.utf8, L=32)
    public static func derive(masterKey: MasterKey, kind: SubKeyKind) -> SymmetricKey {
        let inputKM = SymmetricKey(data: masterKey.dataCopy())
        let info = Data(kind.rawValue.utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKM,
            salt: Data(),                  // 空 salt; master 已带 16 字节 salt 派生过
            info: info,
            outputByteCount: 32
        )
    }

    /// 一次派生全部 4 子 key.
    public static func deriveAll(masterKey: MasterKey) -> SubKeySet {
        SubKeySet(
            qcow2Disk:  derive(masterKey: masterKey, kind: .qcow2Disk),
            qcow2Nvram: derive(masterKey: masterKey, kind: .qcow2Nvram),
            swtpm:      derive(masterKey: masterKey, kind: .swtpm),
            config:     derive(masterKey: masterKey, kind: .config)
        )
    }
}
