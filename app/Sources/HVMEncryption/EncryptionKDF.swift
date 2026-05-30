// HVMEncryption/EncryptionKDF.swift
// 从 master KEK 派生 4 个 32 字节子 key. HKDF-SHA256, info 字符串区分用途.
//
//   master_KEK = PasswordKDF.deriveMasterKey(...)   // 32 字节
//   sub_keys   = EncryptionKDF.deriveAll(masterKey: master_KEK)
//        ├─ qcow2-disk-key  (32B) → -object secret 注入 qemu-img / qemu-system
//        ├─ qcow2-nvram-key (32B) → 同上, OVMF VARS LUKS qcow2
//        ├─ swtpm-key       (32B) → swtpm --key fd= 透传
//        └─ config-key      (32B) → AES.GCM.SealedBox(config.yaml)
//
// HKDF salt 留空: master_KEK 已是 PBKDF2(password, 16B random salt) 派生, 自带高熵.
// info 字符串当用途上下文; 加新加密点直接加 SubKeyKind, info 唯一不影响老 VM.

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
    /// HKDF<SHA256>(IKM=master, salt=<empty>, info=kind.rawValue.utf8, L=32).
    /// 走 master.withBytes 直接进 SymmetricKey, 不走 dataCopy() 离开 mlock 保护堆.
    public static func derive(masterKey: MasterKey, kind: SubKeyKind) -> SymmetricKey {
        masterKey.withBytes { rawBuf in
            deriveFromRaw(rawBuf: rawBuf, kind: kind)
        }
    }

    /// 一次派生全部 4 子 key. 单次进 mlock buffer 算完 4 个, master KEK 字节暴露面只 1 次.
    public static func deriveAll(masterKey: MasterKey) -> SubKeySet {
        masterKey.withBytes { rawBuf -> SubKeySet in
            SubKeySet(
                qcow2Disk:  deriveFromRaw(rawBuf: rawBuf, kind: .qcow2Disk),
                qcow2Nvram: deriveFromRaw(rawBuf: rawBuf, kind: .qcow2Nvram),
                swtpm:      deriveFromRaw(rawBuf: rawBuf, kind: .swtpm),
                config:     deriveFromRaw(rawBuf: rawBuf, kind: .config)
            )
        }
    }

    /// 内部 helper: 直接从 mlock raw bytes 跑 HKDF.
    /// SymmetricKey(data:) 拷一次到 CryptoKit 内部 storage, 但其自带 secure 内存 (mach_vm_allocate
    /// + free 前 zero), 跟 mlock 等价不破坏防护.
    private static func deriveFromRaw(rawBuf: UnsafeRawBufferPointer, kind: SubKeyKind) -> SymmetricKey {
        let inputKM = SymmetricKey(data: Data(rawBuf))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKM,
            salt: Data(),                  // 空 salt; master 已带 16 字节 salt 派生过
            info: Data(kind.rawValue.utf8),
            outputByteCount: 32
        )
    }
}
