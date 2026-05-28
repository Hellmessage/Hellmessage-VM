// protocol.rs — HVM guest helper IPC 协议.
//
// 帧格式: 4-byte BIG-endian u32 length + JSON UTF-8 body. 跟 HVMIPC/Frame.swift 同款,
// 保证 host 端 SocketClient 复用零成本.
//
// 没有 stream / push: helper 始终是 request-response, host 主动发, helper 回. 不存在
// helper → host 主动消息 (v1 不做 guest → host 反向剪贴板).

use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};

pub const PROTOCOL_VERSION: &str = "1.0.0";

/// 单帧最大 size (32 MiB). 实际用例:
///   - ping / clear-clipboard: ~50 B
///   - set-clipboard with N paths: 每路径 < 4 KiB, 100 paths < 1 MiB
/// 上限取大点防异常请求撑爆 parser; 真到 32 MB 是 bug.
pub const MAX_FRAME_BYTES: u32 = 32 * 1024 * 1024;

// ---- request ----

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
pub enum Request {
    /// 健康探测. 立即回 ok.
    Ping {
        #[serde(default)]
        id: Option<String>,
    },
    /// 设 Windows clipboard 为 CF_HDROP, 指向 paths 列表 (guest 端绝对路径).
    SetClipboard {
        #[serde(default)]
        id: Option<String>,
        paths: Vec<String>,
    },
    /// 清空 Windows clipboard.
    ClearClipboard {
        #[serde(default)]
        id: Option<String>,
    },
}

// ---- response ----

#[derive(Debug, Serialize)]
pub struct Response {
    pub id: Option<String>,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl Response {
    pub fn ok(id: Option<String>) -> Self {
        Self { id, ok: true, version: None, code: None, message: None }
    }
    pub fn ok_with_version(id: Option<String>, version: &str) -> Self {
        Self { id, ok: true, version: Some(version.to_string()), code: None, message: None }
    }
    pub fn fail(id: Option<String>, code: &str, message: &str) -> Self {
        Self { id, ok: false, version: None, code: Some(code.to_string()), message: Some(message.to_string()) }
    }
}

// ---- framing ----

/// 读一个完整 frame 的 JSON body. EOF (read = 0) 返 Ok(None) 让 caller 退出循环.
/// 帧 size 越界 / IO 错抛 io::Error.
pub fn read_frame<R: Read>(r: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match read_exact_or_eof(r, &mut len_buf)? {
        ReadResult::Eof => Ok(None),
        ReadResult::Partial(n) => Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            format!("truncated length prefix: got {} of 4 bytes", n),
        )),
        ReadResult::Full => {
            let len = u32::from_be_bytes(len_buf);
            if len == 0 || len > MAX_FRAME_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("invalid frame length: {} (max {})", len, MAX_FRAME_BYTES),
                ));
            }
            let mut body = vec![0u8; len as usize];
            r.read_exact(&mut body)?;
            Ok(Some(body))
        }
    }
}

/// 写一个 frame: 4-byte BE length + body.
pub fn write_frame<W: Write>(w: &mut W, body: &[u8]) -> io::Result<()> {
    let len = body.len() as u32;
    w.write_all(&len.to_be_bytes())?;
    w.write_all(body)?;
    Ok(())
}

enum ReadResult {
    Full,
    Partial(usize),
    Eof,
}

fn read_exact_or_eof<R: Read>(r: &mut R, buf: &mut [u8]) -> io::Result<ReadResult> {
    let mut total = 0;
    while total < buf.len() {
        match r.read(&mut buf[total..]) {
            Ok(0) => {
                return if total == 0 {
                    Ok(ReadResult::Eof)
                } else {
                    Ok(ReadResult::Partial(total))
                };
            }
            Ok(n) => total += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(ReadResult::Full)
}
