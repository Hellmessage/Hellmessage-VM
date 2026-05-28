// Windows GUI subsystem (no console). 不加这条 release build 默认 console subsystem,
// 自启时会闪一个黑窗口很丑. 调试用时改成 "console" 拿 stderr.
#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

// hvm-guest-helper — HVM guest helper service for Windows.
//
// 详见 docs/v3/HOST_FILE_CLIPBOARD.md.
//
// 职责: 跑在 Windows user session, 监听 virtio-serial port
// `\\.\Global\com.hellmessage.hvm-clipboard.0`, 收 host 发来的 JSON 指令, 调
// `OleSetClipboard` + `CF_HDROP` 设系统剪贴板.
//
// 设计原则:
//   - 单线程主循环, 没并发, 简化心智模型
//   - 自动重连: virtio-serial 断 (host 重启 / VM 重启) 自动 retry, 不退出
//   - 失败不 panic: 任何 op error 走日志 + 回 fail response, 主循环继续
//   - 最小依赖: windows + serde + serde_json. 总二进制 ~500 KB
//
// 协议详见 protocol.rs.
// virtio-serial port 详见 virtio.rs.
// CF_HDROP clipboard set 详见 clipboard.rs.

mod clipboard;
mod log;
mod protocol;
mod virtio;

use std::thread;
use std::time::Duration;

use protocol::{read_frame, write_frame, Request, Response, PROTOCOL_VERSION};
use virtio::{VirtioSerialPort, HVM_CLIPBOARD_PORT};

const RETRY_INTERVAL: Duration = Duration::from_secs(5);

fn main() {
    // 始终至少试一下: 多级 fallback 让 init 几乎不可能全部失败.
    // 失败不致命 (helper 还能跑, 只是没 log 排查难)
    let _ = log::init();
    hvmlog!("hvm-guest-helper v{} 启动", env!("CARGO_PKG_VERSION"));

    // 额外兜底 marker: 写到 %TEMP% (用户总可写, 不受 UAC 限制).
    // 让外部诊断"helper 是否真跑过"时有直接证据
    // (Get-Item $env:TEMP\hvm-helper-start.txt).
    let marker_path = std::env::temp_dir().join("hvm-helper-start.txt");
    let _ = std::fs::write(
        &marker_path,
        format!("hvm-guest-helper v{} 启动 pid={}\n",
                env!("CARGO_PKG_VERSION"), std::process::id()),
    );
    hvmlog!("startup marker: {}", marker_path.display());

    // 主循环: 打开 → 服务 → 出错关 → 等 5s → 再打开. 死循环, 进程靠 OS / scheduler kill.
    loop {
        match VirtioSerialPort::open(HVM_CLIPBOARD_PORT) {
            Ok(mut port) => {
                hvmlog!("virtio-serial 打开成功 ({})", HVM_CLIPBOARD_PORT);
                serve_loop(&mut port);
                hvmlog!("serve_loop 退出, {} 秒后重连", RETRY_INTERVAL.as_secs());
            }
            Err(e) => {
                hvmlog!("打开 virtio-serial 失败 ({}): {}", HVM_CLIPBOARD_PORT, e);
            }
        }
        thread::sleep(RETRY_INTERVAL);
    }
}

/// 单连接 serve. EOF / 严重 IO 错误时返回, 让 main 重连.
fn serve_loop(port: &mut VirtioSerialPort) {
    loop {
        // 读一帧
        let body = match read_frame(port) {
            Ok(Some(b)) => b,
            Ok(None) => {
                hvmlog!("peer 关连接 (EOF)");
                return;
            }
            Err(e) => {
                hvmlog!("read_frame 失败: {}", e);
                return;
            }
        };

        // 分派
        let resp = match serde_json::from_slice::<Request>(&body) {
            Ok(req) => dispatch(req),
            Err(e) => {
                hvmlog!("JSON 解析失败: {} (body={} bytes)", e, body.len());
                Response::fail(None, "protocol.decode_failed", &format!("JSON decode: {e}"))
            }
        };

        // 写响应
        let resp_bytes = match serde_json::to_vec(&resp) {
            Ok(b) => b,
            Err(e) => {
                hvmlog!("响应编码失败: {}", e);
                continue;
            }
        };
        if let Err(e) = write_frame(port, &resp_bytes) {
            hvmlog!("write_frame 失败: {}", e);
            return;
        }
    }
}

fn dispatch(req: Request) -> Response {
    match req {
        Request::Ping { id } => {
            hvmlog!("ping");
            Response::ok_with_version(id, PROTOCOL_VERSION)
        }
        Request::SetClipboard { id, paths } => {
            hvmlog!("set-clipboard ({} paths)", paths.len());
            match clipboard::set_file_list(&paths) {
                Ok(()) => Response::ok(id),
                Err(e) => {
                    hvmlog!("set-clipboard 失败: {}", e);
                    Response::fail(id, "clipboard.set_failed", &format!("{e}"))
                }
            }
        }
        Request::ClearClipboard { id } => {
            hvmlog!("clear-clipboard");
            match clipboard::clear() {
                Ok(()) => Response::ok(id),
                Err(e) => {
                    hvmlog!("clear-clipboard 失败: {}", e);
                    Response::fail(id, "clipboard.clear_failed", &format!("{e}"))
                }
            }
        }
    }
}
