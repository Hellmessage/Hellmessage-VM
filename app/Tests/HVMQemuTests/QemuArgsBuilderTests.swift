// HVMQemuTests/QemuArgsBuilderTests.swift
// 纯函数测试: 给定 VMConfig + 路径, argv 关键 flag 必须在场.

import XCTest
@testable import HVMQemu
import HVMBundle
import HVMCore

final class QemuArgsBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func makeInputs(
        config: VMConfig,
        bundlePath: String = "/tmp/hvm-test/foo.hvmz",
        qemuRoot: String = "/opt/test/qemu",
        qmpPath: String = "/tmp/hvm-test/run/foo.qmp",
        virtioWinISOPath: String? = nil,
        swtpmSocketPath: String? = nil
    ) -> QemuArgsBuilder.Inputs {
        QemuArgsBuilder.Inputs(
            config: config,
            bundleURL: URL(fileURLWithPath: bundlePath, isDirectory: true),
            qemuRoot: URL(fileURLWithPath: qemuRoot, isDirectory: true),
            qmpSocketPath: qmpPath,
            virtioWinISOPath: virtioWinISOPath,
            swtpmSocketPath: swtpmSocketPath
        )
    }

    private func linuxConfig(
        bootFromDiskOnly: Bool = false,
        installerISO: String? = "/tmp/ubuntu-arm64.iso"
    ) -> VMConfig {
        VMConfig(
            displayName: "ubuntu",
            guestOS: .linux,
            engine: .qemu,
            cpuCount: 4,
            memoryMiB: 4096,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 32)],
            networks: [NetworkSpec(mode: .nat, macAddress: "02:11:22:33:44:55")],
            installerISO: installerISO,
            bootFromDiskOnly: bootFromDiskOnly,
            linux: LinuxSpec()
        )
    }

    // MARK: - Linux 基本 argv

    func testLinuxBasicArgsContainsKeyFlags() throws {
        let args = try QemuArgsBuilder.build(makeInputs(config: linuxConfig()))

        // 机器 / CPU / 加速器
        XCTAssertTrue(args.containsPair("-machine", "virt,gic-version=3"))
        XCTAssertTrue(args.containsPair("-cpu", "host"))
        XCTAssertTrue(args.containsPair("-accel", "hvf"))
        // 资源
        XCTAssertTrue(args.containsPair("-smp", "4"))
        XCTAssertTrue(args.containsPair("-m", "4096M"))
        XCTAssertTrue(args.containsPair("-name", "ubuntu"))
        // 控制
        XCTAssertTrue(args.contains("-no-reboot"))
        XCTAssertTrue(args.containsPair("-monitor", "none"))
        // 显示
        XCTAssertTrue(args.containsPair("-display", "cocoa"))
    }

    func testLinuxUsesSingleBiosNotPflash() throws {
        let args = try QemuArgsBuilder.build(makeInputs(config: linuxConfig()))
        XCTAssertTrue(args.contains("-bios"))
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("if=pflash") }),
                       "Linux 走 -bios 单文件, 不用 pflash 双 drive")
    }

    func testQmpUnixSocketServer() throws {
        let inputs = makeInputs(config: linuxConfig())
        let args = try QemuArgsBuilder.build(inputs)
        // QMP socket: server=on,wait=off, 必须是 unix:, 严禁 TCP
        XCTAssertTrue(args.containsPair(
            "-qmp", "unix:/tmp/hvm-test/run/foo.qmp,server=on,wait=off"
        ))
        XCTAssertFalse(args.contains(where: { $0.hasPrefix("tcp:") }),
                       "QMP 不能监听 TCP (CLAUDE.md QEMU 后端约束)")
    }

    // MARK: - 磁盘 / ISO

    func testMainDiskRendersAsVirtioBlk() throws {
        let args = try QemuArgsBuilder.build(makeInputs(config: linuxConfig()))
        let drive = args.afterFlag("-drive")
        XCTAssertNotNil(drive)
        XCTAssertTrue(drive!.contains("file=/tmp/hvm-test/foo.hvmz/disks/main.img"))
        XCTAssertTrue(drive!.contains("if=virtio"))
        XCTAssertTrue(drive!.contains("format=raw"))
        XCTAssertTrue(drive!.contains("cache=none"))
    }

    func testISOAttachedAsCdromInInstallerMode() throws {
        let args = try QemuArgsBuilder.build(makeInputs(config: linuxConfig()))
        let cdromDrive = args.allFlagValues("-drive")
            .first(where: { $0.contains("media=cdrom") })
        XCTAssertNotNil(cdromDrive, "installer 模式必须挂 ISO")
        XCTAssertTrue(cdromDrive!.contains("file=/tmp/ubuntu-arm64.iso"))
        XCTAssertTrue(cdromDrive!.contains("readonly=on"))
    }

    func testISOSkippedWhenBootFromDiskOnly() throws {
        let cfg = linuxConfig(bootFromDiskOnly: true, installerISO: "/tmp/x.iso")
        let args = try QemuArgsBuilder.build(makeInputs(config: cfg))
        let cdromDrive = args.allFlagValues("-drive")
            .first(where: { $0.contains("media=cdrom") })
        XCTAssertNil(cdromDrive, "bootFromDiskOnly=true 时不挂 ISO")
    }

    func testISOSkippedWhenNoInstaller() throws {
        let cfg = linuxConfig(bootFromDiskOnly: false, installerISO: nil)
        let args = try QemuArgsBuilder.build(makeInputs(config: cfg))
        let cdromDrive = args.allFlagValues("-drive")
            .first(where: { $0.contains("media=cdrom") })
        XCTAssertNil(cdromDrive)
    }

    // MARK: - 网络

    func testNATNetworkRendersUserDevice() throws {
        let args = try QemuArgsBuilder.build(makeInputs(config: linuxConfig()))
        XCTAssertTrue(args.allFlagValues("-netdev")
            .contains(where: { $0.hasPrefix("user,") && $0.contains("id=net0") }))
        XCTAssertTrue(args.allFlagValues("-device")
            .contains(where: { $0.hasPrefix("virtio-net-pci")
                            && $0.contains("netdev=net0")
                            && $0.contains("mac=02:11:22:33:44:55") }))
    }

    func testBridgedNetworkThrowsForNow() {
        var cfg = linuxConfig()
        cfg.networks = [NetworkSpec(mode: .bridged(interface: "en0"),
                                    macAddress: "02:00:00:00:00:01")]
        XCTAssertThrowsError(try QemuArgsBuilder.build(makeInputs(config: cfg)))
    }

    // MARK: - guestOS 边界

    func testMacOSGuestThrows() {
        let cfg = VMConfig(
            displayName: "mac",
            guestOS: .macOS,
            engine: .vz,                       // validate() 实际会拦, 这里测兜底
            cpuCount: 2, memoryMiB: 4096,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 80)]
        )
        XCTAssertThrowsError(try QemuArgsBuilder.build(makeInputs(config: cfg)))
    }

    // MARK: - Windows: pflash + TPM

    func testWindowsUsesPflashDoubleAndTPM() throws {
        let cfg = VMConfig(
            displayName: "win11",
            guestOS: .windows,
            engine: .qemu,
            cpuCount: 4, memoryMiB: 8192,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 64)],
            networks: [NetworkSpec(mode: .nat, macAddress: "02:de:ad:be:ef:01")],
            installerISO: "/tmp/win11-arm64.iso",
            bootFromDiskOnly: false,
            windows: WindowsSpec(secureBoot: true, tpmEnabled: true)
        )
        let args = try QemuArgsBuilder.build(makeInputs(
            config: cfg, swtpmSocketPath: "/tmp/run/abc.swtpm.sock"
        ))

        // pflash 双 drive: RO code + RW vars
        let pflash = args.allFlagValues("-drive").filter { $0.contains("if=pflash") }
        XCTAssertEqual(pflash.count, 2, "Windows 必须有两个 pflash drive (code RO + vars RW)")
        XCTAssertTrue(pflash.contains(where: { $0.contains("readonly=on") }),
                      "code 那条必须 readonly=on")
        XCTAssertTrue(pflash.contains(where: { !$0.contains("readonly=on") }),
                      "vars 那条不能 readonly")

        // -bios 不应出现 (Windows 走 pflash, 不走 -bios)
        XCTAssertFalse(args.contains("-bios"))

        // TPM 三件套
        XCTAssertTrue(args.allFlagValues("-chardev")
            .contains(where: { $0.contains("id=chartpm") && $0.contains("socket") }))
        XCTAssertTrue(args.allFlagValues("-tpmdev")
            .contains(where: { $0.contains("emulator") && $0.contains("chardev=chartpm") }))
        XCTAssertTrue(args.allFlagValues("-device")
            .contains(where: { $0.hasPrefix("tpm-tis-device") && $0.contains("tpmdev=tpm0") }))
    }

    func testWindowsTPMSkippedWhenDisabled() throws {
        let cfg = VMConfig(
            displayName: "win-no-tpm",
            guestOS: .windows,
            engine: .qemu,
            cpuCount: 2, memoryMiB: 4096,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 32)],
            windows: WindowsSpec(secureBoot: false, tpmEnabled: false)
        )
        let args = try QemuArgsBuilder.build(makeInputs(
            config: cfg, swtpmSocketPath: "/tmp/abc.swtpm.sock"
        ))
        XCTAssertFalse(args.contains("-tpmdev"),
                       "tpmEnabled=false 时即便给了 swtpm socket 也不注入 -tpmdev")
    }

    func testWindowsTPMSkippedWhenSocketPathMissing() throws {
        // tpmEnabled=true 但调用方没启 swtpm (没传 socket): 不注入 TPM device
        // (Win11 装机会失败, 但起码 QEMU 不会因连接不存在的 socket 而崩)
        let cfg = VMConfig(
            displayName: "win-tpm-no-sock",
            guestOS: .windows,
            engine: .qemu,
            cpuCount: 2, memoryMiB: 4096,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 32)],
            windows: WindowsSpec(secureBoot: true, tpmEnabled: true)
        )
        // 注意: swtpmSocketPath 未传 (默认 nil)
        let args = try QemuArgsBuilder.build(makeInputs(config: cfg))
        XCTAssertFalse(args.contains("-tpmdev"),
                       "swtpmSocketPath=nil 时不注入 TPM device, 避免 QEMU 连不存在的 socket")
    }

    // MARK: - virtio-win 第二 cdrom (Win11 装机驱动)

    func testWindowsVirtioWinAttachedAsSecondCdrom() throws {
        let cfg = VMConfig(
            displayName: "win11",
            guestOS: .windows, engine: .qemu,
            cpuCount: 4, memoryMiB: 8192,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 64)],
            installerISO: "/tmp/win11.iso",
            bootFromDiskOnly: false,
            windows: WindowsSpec()
        )
        let args = try QemuArgsBuilder.build(makeInputs(
            config: cfg, virtioWinISOPath: "/Users/me/cache/virtio-win/virtio-win.iso"
        ))
        let cdroms = args.allFlagValues("-drive").filter { $0.contains("media=cdrom") }
        XCTAssertEqual(cdroms.count, 2, "Win11 应挂 2 个 cdrom: 安装 ISO + virtio-win")
        XCTAssertTrue(cdroms.contains(where: { $0.contains("/tmp/win11.iso") }))
        XCTAssertTrue(cdroms.contains(where: { $0.contains("virtio-win.iso") }))
    }

    func testLinuxIgnoresVirtioWinPath() throws {
        let cfg = linuxConfig()
        let args = try QemuArgsBuilder.build(makeInputs(
            config: cfg, virtioWinISOPath: "/Users/me/virtio-win.iso"
        ))
        let cdroms = args.allFlagValues("-drive").filter { $0.contains("media=cdrom") }
        // 仅 Linux 安装 ISO 一个 cdrom; virtio-win 仅 Windows 用
        XCTAssertEqual(cdroms.count, 1)
        XCTAssertFalse(cdroms.contains(where: { $0.contains("virtio-win") }))
    }

    func testWindowsWithoutVirtioWinPathIsSingleCdrom() throws {
        let cfg = VMConfig(
            displayName: "win11",
            guestOS: .windows, engine: .qemu,
            cpuCount: 2, memoryMiB: 4096,
            disks: [DiskSpec(role: .main, path: "disks/main.img", sizeGiB: 32)],
            installerISO: "/tmp/win11.iso",
            windows: WindowsSpec()
        )
        // 没传 virtioWinISOPath; 仍应能构造 (虽然装机会因缺驱动看不见盘)
        let args = try QemuArgsBuilder.build(makeInputs(config: cfg))
        let cdroms = args.allFlagValues("-drive").filter { $0.contains("media=cdrom") }
        XCTAssertEqual(cdroms.count, 1)
    }
}

// MARK: - argv 检查辅助

private extension Array where Element == String {
    /// flag value 紧跟 flag name 的形态: ["-machine", "virt"]
    func containsPair(_ flag: String, _ value: String) -> Bool {
        for i in 0..<count - 1 {
            if self[i] == flag, self[i + 1] == value { return true }
        }
        return false
    }

    /// 取第一次出现的 flag 后面紧跟的 value
    func afterFlag(_ flag: String) -> String? {
        for i in 0..<count - 1 where self[i] == flag {
            return self[i + 1]
        }
        return nil
    }

    /// 取所有 flag 出现处的 value (-drive 可重复)
    func allFlagValues(_ flag: String) -> [String] {
        var out: [String] = []
        for i in 0..<count - 1 where self[i] == flag {
            out.append(self[i + 1])
        }
        return out
    }
}
