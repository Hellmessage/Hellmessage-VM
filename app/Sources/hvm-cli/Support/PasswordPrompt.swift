// hvm-cli/Support/PasswordPrompt.swift
// 加密 VM 操作 (start / encrypt / decrypt / rekey) 的密码输入助手.
// 走 BSD readpassphrase(3) — 关闭终端 echo, 不显示用户输入字符.
//
// 设计稿 docs/v3/ENCRYPTION.md v2.4: 强制每次输入密码, 不缓存到 Keychain.

import Foundation
import Darwin
import HVMCore

public enum PasswordPrompt {
    /// 提示用户输入密码 (终端不回显). 失败 (无 tty / 用户 Ctrl-D) 抛 HVMError.
    /// confirm = true 时要求二次确认 (创建 VM / 改密时用).
    public static func read(prompt: String,
                             confirm: Bool = false,
                             minLength: Int = 1) throws -> String {
        let pw1 = try promptOnce(prompt)
        guard pw1.count >= minLength else {
            throw HVMError.config(.invalidEnum(
                field: "password",
                raw: "长度=\(pw1.count)",
                allowed: ["≥ \(minLength) 字符"]
            ))
        }
        if confirm {
            let pw2 = try promptOnce("再次输入确认: ")
            guard pw1 == pw2 else {
                throw HVMError.config(.invalidEnum(
                    field: "password",
                    raw: "两次输入不一致",
                    allowed: ["两次输入相同"]
                ))
            }
        }
        return pw1
    }

    /// 单次 prompt. 走 readpassphrase(3) — RPP_REQUIRE_TTY 强制要 tty,
    /// 防 stdin pipe 时打印密码到日志.
    private static func promptOnce(_ prompt: String) throws -> String {
        var buf = [Int8](repeating: 0, count: 1024)
        let result = prompt.withCString { promptPtr in
            // RPP_REQUIRE_TTY = 0x02
            readpassphrase(promptPtr, &buf, buf.count, 0x02)
        }
        guard let cStr = result else {
            throw HVMError.config(.invalidEnum(
                field: "password",
                raw: "无法读取 (errno=\(errno), 可能非 tty 环境)",
                allowed: ["tty 输入"]
            ))
        }
        return String(cString: cStr)
    }
}

/// readpassphrase(3) C 声明. macOS 自带 (declared in <readpassphrase.h>).
@_silgen_name("readpassphrase")
private func readpassphrase(
    _ prompt: UnsafePointer<CChar>?,
    _ buf: UnsafeMutablePointer<CChar>?,
    _ bufsiz: Int,
    _ flags: Int32
) -> UnsafeMutablePointer<CChar>?
