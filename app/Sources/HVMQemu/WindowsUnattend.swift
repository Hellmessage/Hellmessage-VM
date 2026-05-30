// HVMQemu/WindowsUnattend.swift
// 生成 AutoUnattend.xml + 用 hdiutil makehybrid 打成 ISO9660+UDF 混合 ISO, 作 cdrom 给 Win Setup 自动读.
//
// 用途:
//   - bypassInstallChecks: windowsPE pass reg add LabConfig\Bypass*Check=1 跳硬件检查
//   - autoInstallVirtioWin: oobeSystem FirstLogonCommands 首登扫盘符 certutil + pnputil 装 virtio 驱动
//
// 纯命名空间无状态; 幂等 (XML 未变复用现有 ISO); hdiutil 是 macOS 自带零外部依赖.

import Foundation
import HVMBundle
import HVMCore

public enum WindowsUnattend {

    public enum Error: Swift.Error, Sendable {
        case hdiutilFailed(status: Int32, output: String)
        case writeFailed(reason: String)
    }

    /// 确保 bundle 下有最新 AutoUnattend ISO. 内容跟开关变化则重打.
    /// - Parameters:
    ///   - bundle: VM bundle 根目录 (.hvmz)
    ///   - bypassInstallChecks: 加 windowsPE pass reg add LabConfig\Bypass*Check
    ///   - autoInstallVirtioWin: 加 oobeSystem pass FirstLogonCommands pnputil 装驱动
    ///   - autoInstallSpiceTools: oobeSystem FirstLogonCommands 扫盘符跑 utm-guest-tools-*.exe /S
    ///     静默装. 依赖 QemuArgsBuilder 把 utm-guest-tools.iso 当 cdrom 挂; 缺 ISO 时 cmd noop 不阻塞.
    /// - Returns: unattend ISO 的 URL
    public static func ensureISO(
        bundle: URL,
        bypassInstallChecks: Bool,
        autoInstallVirtioWin: Bool,
        autoInstallSpiceTools: Bool = false
    ) throws -> URL {
        let fm = FileManager.default
        let xml = unattendXML(
            bypassInstallChecks: bypassInstallChecks,
            autoInstallVirtioWin: autoInstallVirtioWin,
            autoInstallSpiceTools: autoInstallSpiceTools
        )
        let stageDir = BundleLayout.unattendStageDir(bundle)
        // 三份文件名都写 (不同 Win Setup 版本对大小写要求不一): Autounattend / autounattend / unattend.xml
        let canonicalURL = stageDir.appendingPathComponent("Autounattend.xml")
        let lowerURL = stageDir.appendingPathComponent("autounattend.xml")
        let shortURL = stageDir.appendingPathComponent("unattend.xml")
        let isoURL = BundleLayout.unattendISOURL(bundle)

        // 幂等: ISO 已存在 + canonical XML 存在 + 内容一致 → 复用
        if fm.fileExists(atPath: isoURL.path),
           fm.fileExists(atPath: canonicalURL.path),
           let existing = try? String(contentsOf: canonicalURL, encoding: .utf8),
           existing == xml {
            return isoURL
        }

        // 重建 stage (只含 unattend xml; utm-guest-tools.iso 不拷, 走 cdrom 挂)
        try? fm.removeItem(at: stageDir)
        do {
            try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
            try xml.write(to: canonicalURL, atomically: true, encoding: .utf8)
            try xml.write(to: lowerURL, atomically: true, encoding: .utf8)
            try xml.write(to: shortURL, atomically: true, encoding: .utf8)
        } catch {
            throw Error.writeFailed(reason: "stage 写入失败: \(error)")
        }

        // hdiutil makehybrid 打 ISO9660+UDF 混合 (Win Setup 两层都能读)
        try? fm.removeItem(at: isoURL)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = [
            "makehybrid",
            "-udf", "-iso",
            "-iso-volume-name", "HVM_UNATTEND",
            "-udf-volume-name", "HVM_UNATTEND",
            "-o", isoURL.path,
            stageDir.path,
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            throw Error.writeFailed(reason: "hdiutil 启动失败: \(error)")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let out = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw Error.hdiutilFailed(status: proc.terminationStatus, output: out)
        }
        return isoURL
    }

    // MARK: - XML 构造

    /// AutoUnattend.xml 内容.
    /// windowsPE pass: reg add LabConfig\Bypass*Check=0x1 跳硬件检查.
    /// oobeSystem pass: FirstLogonCommands pnputil 装 virtio 驱动 + utm-guest-tools /S 静默装.
    static func unattendXML(
        bypassInstallChecks: Bool,
        autoInstallVirtioWin: Bool,
        autoInstallSpiceTools: Bool = false
    ) -> String {
        var commands: [(cmd: String, desc: String)] = []
        if autoInstallVirtioWin {
            // ARM64 Windows: virtio-win.iso 不带 ARM64 MSI, 走 inf 分发. 扫所有盘符找 %D:\NetKVM:
            // 1) certutil 装 Red Hat 代码签名证书进 TrustedPublisher (否则 inf 证书链不受信被拒).
            //    **要点**: -addstore 不接受 wildcard, 必须 nested for 遍历 .cer 单文件 + 引号包路径.
            // 2) pnputil /add-driver. **要点**: 路径必须 wildcard %D:\*.inf + /subdirs, 裸目录报 0 packages.
            // 3) pnputil /scan-devices 重新枚举设备, 让首登就有网不必 reboot.
            // 4) stdout/stderr 全 redirect 到 C:\HVM-virtio-install.log 便于排错.
            // XML 里 & → &amp;, > → &gt; (cmd 重定向 / 多命令分隔符).
            let log = "C:\\HVM-virtio-install.log"
            let cmd = """
            cmd /c \
            echo === HVM virtio-install %DATE% %TIME% === &gt; \(log) 2&gt;&amp;1 \
            &amp; for %D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist %D:\\NetKVM ( \
            echo --- found virtio-win at %D: --- &gt;&gt; \(log) \
            &amp; for %F in (%D:\\cert\\*.cer) do @certutil -addstore -f TrustedPublisher "%F" &gt;&gt; \(log) 2&gt;&amp;1 \
            &amp; pnputil /add-driver %D:\\*.inf /subdirs /install &gt;&gt; \(log) 2&gt;&amp;1 \
            ) \
            &amp; echo --- scan-devices --- &gt;&gt; \(log) \
            &amp; pnputil /scan-devices &gt;&gt; \(log) 2&gt;&amp;1
            """.replacingOccurrences(of: "\n", with: "")
            commands.append((cmd, "HVM auto-install virtio-win drivers (ARM64)"))
        }
        if autoInstallSpiceTools {
            // utm-guest-tools-*.exe 是 NSIS installer (UTM 自家打包, 含 ARM64 native vdagent +
            // viogpudo.sys). stock spice-guest-tools.exe 只 x86, ARM Win 走不通 dynamic resize.
            // 扫所有盘符找 .exe + start /wait (装完才进下条命令); 缺 ISO 时 noop 不阻塞 OOBE.
            let cmd = "cmd /c for %D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do @for %F in (%D:\\utm-guest-tools-*.exe) do @if exist %F start /wait %F /S"
            commands.append((cmd, "HVM auto-install UTM Guest Tools (ARM64 vdagent + viogpudo for dynamic resize)"))
        }

        var oobeBlock = ""
        if !commands.isEmpty {
            var synchronousCommands = ""
            for (idx, item) in commands.enumerated() {
                synchronousCommands += """
                    <SynchronousCommand wcm:action="add">
                      <Order>\(idx + 1)</Order>
                      <CommandLine>\(item.cmd)</CommandLine>
                      <Description>\(item.desc)</Description>
                      <RequiresUserInput>false</RequiresUserInput>
                    </SynchronousCommand>

                """
            }
            oobeBlock = """

              <settings pass="oobeSystem">
                <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                  <FirstLogonCommands>
            \(synchronousCommands.trimmingCharacters(in: .whitespacesAndNewlines))
                  </FirstLogonCommands>
                </component>
              </settings>
            """
        }

        // bypassInstallChecks 关闭时不写 windowsPE 段, 仍可作 oobe-only unattend
        var windowsPEBlock = ""
        if bypassInstallChecks {
            windowsPEBlock = """

              <settings pass="windowsPE">
                <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                  <RunSynchronous>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>1</Order>
                      <Path>reg add HKLM\\System\\Setup\\LabConfig /f</Path>
                      <Description>create LabConfig</Description>
                    </RunSynchronousCommand>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>2</Order>
                      <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 0x1 /f</Path>
                    </RunSynchronousCommand>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>3</Order>
                      <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 0x1 /f</Path>
                    </RunSynchronousCommand>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>4</Order>
                      <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 0x1 /f</Path>
                    </RunSynchronousCommand>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>5</Order>
                      <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 0x1 /f</Path>
                    </RunSynchronousCommand>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>6</Order>
                      <Path>reg add HKLM\\System\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 0x1 /f</Path>
                    </RunSynchronousCommand>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>7</Order>
                      <Path>reg add HKLM\\System\\Setup\\MoSetup /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 0x1 /f</Path>
                      <Description>legacy upgrade-path bypass</Description>
                    </RunSynchronousCommand>
                  </RunSynchronous>
                </component>
              </settings>
            """
        }

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">\(windowsPEBlock)\(oobeBlock)
        </unattend>
        """
    }
}
