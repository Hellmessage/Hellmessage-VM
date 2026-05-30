// virtio.rs — 打开 Windows virtio-serial 端口的 read/write 句柄.
//
// QEMU 端 chardev:
//   -chardev socket,id=hvmclipboard,path=...,server=on,wait=off
//   -device virtserialport,bus=vsp0.0,chardev=hvmclipboard,
//            name=com.hellmessage.hvm-clipboard.0
//
// Windows 端 virtio-serial driver (UTM Guest Tools 自带 virtio-win driver) 把每个
// virtserialport 暴露成一个特殊设备路径:
//
//   \\.\Global\com.hellmessage.hvm-clipboard.0
//
// CreateFileW 打开, 拿 HANDLE, 后续 ReadFile / WriteFile 同步 IO.
//
// Note: spice-vdagent.exe 走同款 API 打开 com.redhat.spice.0; qga 走
// org.qemu.guest_agent.0. 我们的 port name 跟它们 namespace 完全隔离, 不冲突.

use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::ptr;

use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, ReadFile, WriteFile, FILE_FLAGS_AND_ATTRIBUTES, FILE_GENERIC_READ,
    FILE_GENERIC_WRITE, FILE_SHARE_NONE, OPEN_EXISTING,
};

pub const HVM_CLIPBOARD_PORT: &str = r"\\.\Global\com.hellmessage.hvm-clipboard.0";

/// 一个已打开的 virtio-serial 端口. Drop 时关 HANDLE.
/// 实现 Read + Write, 让 protocol::read_frame / write_frame 直接吃.
pub struct VirtioSerialPort {
    handle: HANDLE,
}

// HANDLE 在 windows-rs 是裸指针, 不自动 Send/Sync. 我们只在单线程主循环用, 标
// Send 给跨 await/线程边界用例预留 (v1 用不到).
unsafe impl Send for VirtioSerialPort {}

impl VirtioSerialPort {
    /// 打开 port path. 失败返 io::Error (kind=NotFound / PermissionDenied / Other 等).
    /// 调用方一般跑在 retry loop 里, 端口不在 (VM 刚启动 driver 没加载完 / virtio 未协商完)
    /// 时会失败, 等几秒再试.
    pub fn open(path: &str) -> io::Result<Self> {
        // path → UTF-16 null-terminated
        let path_wide: Vec<u16> = OsString::from(path).encode_wide().chain(std::iter::once(0)).collect();

        // SAFETY: path_wide 在调用期间有效; CreateFileW 不持有指针.
        // 不开 FILE_FLAG_OVERLAPPED — 走同步 IO, 协议是 request-response 单线程模型,
        // 不需要 overlapped 并发. 简化代码 + 减少状态.
        let handle = unsafe {
            CreateFileW(
                PCWSTR(path_wide.as_ptr()),
                (FILE_GENERIC_READ | FILE_GENERIC_WRITE).0,
                FILE_SHARE_NONE,
                None,
                OPEN_EXISTING,
                FILE_FLAGS_AND_ATTRIBUTES(0),   // 同步 IO, 不要 OVERLAPPED
                None,
            )
        }
        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("CreateFileW failed: {e}")))?;

        if handle.is_invalid() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("virtio-serial port not found: {}", path),
            ));
        }

        Ok(Self { handle })
    }
}

impl Drop for VirtioSerialPort {
    fn drop(&mut self) {
        if !self.handle.is_invalid() {
            // SAFETY: handle 由 CreateFileW 返回, 仅在本 Drop 关一次.
            unsafe { let _ = CloseHandle(self.handle); }
        }
    }
}

impl Read for VirtioSerialPort {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let mut bytes_read: u32 = 0;
        // SAFETY: buf 在调用期有效; ReadFile 同步阻塞.
        unsafe {
            ReadFile(
                self.handle,
                Some(buf),
                Some(&mut bytes_read as *mut u32),
                None,
            )
        }
        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("ReadFile failed: {e}")))?;
        Ok(bytes_read as usize)
    }
}

impl Write for VirtioSerialPort {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let mut bytes_written: u32 = 0;
        // SAFETY: buf 在调用期有效; WriteFile 同步阻塞.
        unsafe {
            WriteFile(
                self.handle,
                Some(buf),
                Some(&mut bytes_written as *mut u32),
                None,
            )
        }
        .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("WriteFile failed: {e}")))?;
        Ok(bytes_written as usize)
    }

    fn flush(&mut self) -> io::Result<()> {
        // virtio-serial 默认无 user-space buffering, ReadFile/WriteFile 直接走 driver.
        // 显式 flush 没意义.
        Ok(())
    }
}

// 防止 `unused_imports` 警告 (windows-rs feature gating 可能让某些类型 build 时无引用).
#[allow(dead_code)]
fn _unused_anchors() {
    let _ = INVALID_HANDLE_VALUE;
    let _ = ptr::null::<u8>();
}
