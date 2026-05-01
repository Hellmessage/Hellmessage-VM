// HVMQemu/WindowsUnattend.swift
// 生成 AutoUnattend.xml + 用 macOS hdiutil makehybrid 打成 ISO9660+UDF 混合 ISO,
// 启动时作为第二个 cdrom 给 Windows Setup 自动读. 端口自 hell-vm 同名实现.
//
// 用途:
//   - bypassInstallChecks: windowsPE pass 跑 reg add LabConfig\Bypass*Check=1
//     让 Win11 Setup 跳过 TPM/SB/RAM/CPU/Storage 检查
//   - autoInstallVirtioWin: oobeSystem pass 的 FirstLogonCommands 在首次登录时
//     从所有盘符扫 NetKVM 目录, 找到 → certutil + pnputil /add-driver /subdirs /install,
//     ARM64 Windows 自动装 NetKVM/viostor/viogpudo/qemu-ga 驱动.
//
// 设计:
//   - 纯命名空间, 无状态, 不依赖 backend 进程
//   - 幂等: XML 内容未变则复用现有 ISO, 不重打
//   - hdiutil makehybrid 是 macOS 自带 (/usr/bin/hdiutil), 零外部依赖

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
    /// - Returns: unattend ISO 的 URL (可能是新写也可能复用)
    public static func ensureISO(
        bundle: URL,
        bypassInstallChecks: Bool,
        autoInstallVirtioWin: Bool
    ) throws -> URL {
        let xml = unattendXML(
            bypassInstallChecks: bypassInstallChecks,
            autoInstallVirtioWin: autoInstallVirtioWin
        )
        let stageDir = BundleLayout.unattendStageDir(bundle)
        // 三份文件名都写: 不同版本 Win Setup 对大小写要求不一
        //   - Autounattend.xml (MS docs 官方, A 大写)
        //   - autounattend.xml (Win11 24H2 实测更可靠)
        //   - unattend.xml (兜底)
        let canonicalURL = stageDir.appendingPathComponent("Autounattend.xml")
        let lowerURL = stageDir.appendingPathComponent("autounattend.xml")
        let shortURL = stageDir.appendingPathComponent("unattend.xml")
        let isoURL = BundleLayout.unattendISOURL(bundle)

        let fm = FileManager.default

        // 幂等: ISO 已存在 + canonical XML 存在 + 内容一致 → 复用
        if fm.fileExists(atPath: isoURL.path),
           fm.fileExists(atPath: canonicalURL.path),
           let existing = try? String(contentsOf: canonicalURL, encoding: .utf8),
           existing == xml {
            return isoURL
        }

        // 重建 stage
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

    /// AutoUnattend.xml 内容. 端口自 hell-vm WindowsUnattend.unattendXML.
    ///
    /// windowsPE pass: reg add LabConfig\Bypass*Check=0x1 让 Setup 跳硬件检查.
    /// oobeSystem pass: FirstLogonCommands 跑 cmd /c for ... pnputil 装 virtio 驱动.
    static func unattendXML(
        bypassInstallChecks: Bool,
        autoInstallVirtioWin: Bool
    ) -> String {
        var oobeBlock = ""
        if autoInstallVirtioWin {
            // ARM64 Windows: virtio-win.iso 不带 ARM64 MSI, 走 inf 分发.
            // 1) certutil 把 Red Hat 代码签名证书装进 TrustedPublisher (否则 inf 因证书链不受信任被拒).
            //    **要点**: certutil -addstore 不接受 wildcard 路径 (返 ERROR_INVALID_NAME 0x8007007b),
            //    必须 nested for 遍历 .cer 单文件 + 引号包路径防 space.
            // 2) pnputil /add-driver 递归装. **要点**: 路径必须是 wildcard 形如 %D:\*.inf,
            //    裸目录如 %D:\ 会让 pnputil 找不到 inf 报 "Total driver packages: 0".
            //    实测 virtio-win-0.1.285 用 *.inf + /subdirs 能扫到 \NetKVM\w11\ARM64\netkvm.inf 等.
            // 3) pnputil /scan-devices 强制 PnP manager 重新枚举设备. OOBE 阶段 NIC PCI 设备早就
            //    advertise 了, 但只有装完驱动才有 PnP 绑定; scan-devices 让首登登就有网, 不必 reboot.
            // 4) 全程把 stdout / stderr redirect 到 C:\HVM-virtio-install.log, 失败时 user 能看 log
            //    定位是 certutil 拒签 / pnputil 拒载 / 还是别的.
            // 探测条件保持 %D:\NetKVM (跟 hell-vm 一致, 当前 virtio-win.iso 顶层结构稳定).
            // XML 里 & 必须 escape 成 &amp;, > 必须 escape 成 &gt; (cmd 重定向 / 多命令分隔符).
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
            oobeBlock = """

              <settings pass="oobeSystem">
                <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                  <FirstLogonCommands>
                    <SynchronousCommand wcm:action="add">
                      <Order>1</Order>
                      <CommandLine>\(cmd)</CommandLine>
                      <Description>HVM auto-install virtio-win drivers (ARM64)</Description>
                      <RequiresUserInput>false</RequiresUserInput>
                    </SynchronousCommand>
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
