// clipboard.rs — Windows clipboard CF_HDROP 设置.
//
// 流程 (跟 Win32 文档 "Implementing a Clipboard Source" 一致):
//   1. OpenClipboard(NULL)         — 拿当前 thread 的 user-session clipboard 锁
//   2. EmptyClipboard()             — 清旧内容 + 让我们成为 owner
//   3. GlobalAlloc(GMEM_MOVEABLE)   — 分配 DROPFILES 结构 + path 列表 (UTF-16 + 双 null 终止)
//   4. GlobalLock + memcpy DROPFILES
//   5. GlobalUnlock
//   6. SetClipboardData(CF_HDROP, hGlobal)  — Windows 接管 GlobalAlloc 句柄
//   7. CloseClipboard()
//
// 关键: SetClipboardData 成功后 Windows 拥有 hGlobal 所有权, 我们不能 GlobalFree.
// 失败时我们必须自己 GlobalFree 防漏.
//
// CF_HDROP 数据结构 (DROPFILES + 路径列表):
//
//   struct DROPFILES {
//       DWORD  pFiles;      // offset to path list (= sizeof(DROPFILES) = 20)
//       POINT  pt;          // drop point in client coords (0,0 for clipboard)
//       BOOL   fNC;          // 0
//       BOOL   fWide;        // TRUE = path list is UTF-16, FALSE = ANSI
//   };
//   <pFiles offset>: UTF-16 path 1 \0 path 2 \0 ... path N \0\0  (double-null terminator)

use std::io;
use std::mem;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND, POINT};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_HDROP;

// windows-rs 0.59 没暴露 GlobalFree, 手动 link kernel32. 仅用在 SetClipboardData 失败的
// 错误恢复路径 (成功路径 Windows 接管 HGLOBAL 自动 free, 不需要我们调).
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GlobalFree(hmem: HGLOBAL) -> HGLOBAL;
}

#[repr(C, packed)]
#[allow(non_snake_case)]
struct DROPFILES {
    pFiles: u32,    // offset to path list from struct start
    pt: POINT,      // drop point (0,0 for clipboard)
    fNC: i32,       // 0
    fWide: i32,     // 1 = wide (UTF-16)
}

/// 把给定 guest 端绝对路径列表设为 Windows clipboard 的 CF_HDROP.
/// paths 是 UTF-8, 内部转 UTF-16. 调用方应已验证文件存在.
///
/// 失败返 io::Error. 成功无返回.
pub fn set_file_list(paths: &[String]) -> io::Result<()> {
    if paths.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "paths is empty"));
    }

    // 1. 把所有 path 转 UTF-16, 拼成 path1\0 path2\0 ... pathN\0\0
    let mut path_utf16: Vec<u16> = Vec::new();
    for p in paths {
        let p_wide: Vec<u16> = Path::new(p).as_os_str().encode_wide().collect();
        path_utf16.extend(p_wide);
        path_utf16.push(0);   // 单 path 结尾
    }
    path_utf16.push(0);       // double-null 列表结尾

    let dropfiles_size = mem::size_of::<DROPFILES>();
    let path_bytes = path_utf16.len() * mem::size_of::<u16>();
    let total_size = dropfiles_size + path_bytes;

    // 2. GlobalAlloc GMEM_MOVEABLE — clipboard 要 movable 句柄
    // SAFETY: 0 size 已 guard; total_size 是 dropfiles + N paths < 32 MB 上限.
    let hglobal: HGLOBAL = unsafe {
        GlobalAlloc(GMEM_MOVEABLE, total_size)
            .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("GlobalAlloc: {e}")))?
    };

    // 用一个 RAII guard 防 GlobalAlloc 后续步骤失败时漏 free.
    // SetClipboardData 成功会让 Windows 接管 hglobal — 这时我们 guard.commit() 取消 free.
    struct AllocGuard(HGLOBAL);
    impl Drop for AllocGuard {
        fn drop(&mut self) {
            // SAFETY: hglobal 是 GlobalAlloc 返的有效句柄, 仅在 Drop 时 free 一次.
            unsafe { let _ = GlobalFree(self.0); }
        }
    }
    let mut guard = Some(AllocGuard(hglobal));

    // 3. Lock + 写 DROPFILES 头 + path 列表
    {
        // SAFETY: hglobal 由 GlobalAlloc 返回; GlobalLock 返指向块的指针.
        let raw = unsafe { GlobalLock(hglobal) };
        if raw.is_null() {
            return Err(io::Error::new(io::ErrorKind::Other, "GlobalLock returned NULL"));
        }

        // SAFETY: raw 指向至少 total_size 字节的块.
        unsafe {
            // 写 DROPFILES 头
            let df = DROPFILES {
                pFiles: dropfiles_size as u32,
                pt: POINT { x: 0, y: 0 },
                fNC: 0,
                fWide: 1,
            };
            std::ptr::copy_nonoverlapping(
                &df as *const DROPFILES as *const u8,
                raw as *mut u8,
                dropfiles_size,
            );
            // 写 path 列表 (UTF-16)
            let paths_dst = (raw as *mut u8).add(dropfiles_size) as *mut u16;
            std::ptr::copy_nonoverlapping(path_utf16.as_ptr(), paths_dst, path_utf16.len());

            let _ = GlobalUnlock(hglobal);
        }
    }

    // 4. OpenClipboard + EmptyClipboard + SetClipboardData + CloseClipboard
    // SAFETY: HWND::default() = NULL 表示当前 task 拥有 clipboard, 单线程 main 调用 OK.
    unsafe {
        OpenClipboard(Some(HWND::default()))
            .map_err(|e| io::Error::new(io::ErrorKind::PermissionDenied,
                                          format!("OpenClipboard: {e}")))?;
    }

    // EmptyClipboard / SetClipboard 失败要 CloseClipboard 之后再返 — 用 closure 包.
    let inner_result: io::Result<()> = (|| {
        // SAFETY: 已 OpenClipboard.
        unsafe {
            EmptyClipboard()
                .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("EmptyClipboard: {e}")))?;
        }
        // SetClipboardData. windows-rs 用 HANDLE 接受 hglobal cast.
        // SAFETY: hglobal 仍 valid; CF_HDROP 是标准 clipboard format ID.
        let handle = HANDLE(hglobal.0 as *mut _);
        unsafe {
            SetClipboardData(CF_HDROP.0 as u32, Some(handle))
                .map_err(|e| io::Error::new(io::ErrorKind::Other,
                                              format!("SetClipboardData: {e}")))?;
        }
        // SetClipboardData 成功 → Windows 接管 hglobal, 我们不能再 GlobalFree.
        // 取消 RAII guard.
        let _ = guard.take();
        Ok(())
    })();

    // 不管 inner_result 成功失败, 必须 CloseClipboard.
    // SAFETY: 已 OpenClipboard.
    unsafe { let _ = CloseClipboard(); }

    inner_result
}

/// 清空 Windows clipboard.
pub fn clear() -> io::Result<()> {
    // SAFETY: HWND::default() = NULL.
    unsafe {
        OpenClipboard(Some(HWND::default()))
            .map_err(|e| io::Error::new(io::ErrorKind::PermissionDenied,
                                          format!("OpenClipboard: {e}")))?;
    }
    let r: io::Result<()> = unsafe {
        EmptyClipboard()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, format!("EmptyClipboard: {e}")))
    };
    unsafe { let _ = CloseClipboard(); }
    r
}
