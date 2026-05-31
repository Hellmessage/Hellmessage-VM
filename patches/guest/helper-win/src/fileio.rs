// fileio.rs — host↔guest 文件 blob 传输. Rust 原生宽字符路径 → 无 qemu-ga 的 ANSI mojibake.
// 分块: write/read 带 offset; write 末块 final=true. 都走 base64 在 JSON 帧里传.

use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use base64::Engine;

/// host→guest 写. offset=0 → truncate 创建 (+ 按需建父目录); offset>0 → 在 offset 续写 (分块).
/// 返回本次写入字节数. `_is_final` 当前不影响行为 (调用方语义标记), 保留给未来 (如 flush/校验).
pub fn write_file(path: &str, data_b64: &str, offset: u64, _is_final: bool) -> std::io::Result<u64> {
    let data = base64::engine::general_purpose::STANDARD
        .decode(data_b64)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, format!("base64: {e}")))?;

    if let Some(parent) = Path::new(path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let mut f = if offset == 0 {
        File::create(path)?                       // truncate
    } else {
        OpenOptions::new().write(true).open(path)?
    };
    f.seek(SeekFrom::Start(offset))?;
    f.write_all(&data)?;
    Ok(data.len() as u64)
}

/// guest→host 读. 从 offset 读至多 len 字节, 返回 (base64, eof). len 夹到帧上限内.
pub fn read_file(path: &str, offset: u64, len: u64) -> std::io::Result<(String, bool)> {
    let cap = len.min(crate::protocol::MAX_FRAME_BYTES as u64 / 2); // base64 ~4/3 膨胀, 留余量
    let mut f = File::open(path)?;
    f.seek(SeekFrom::Start(offset))?;
    let mut buf = vec![0u8; cap as usize];
    let mut total = 0usize;
    while total < buf.len() {
        match f.read(&mut buf[total..]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    buf.truncate(total);
    let eof = (total as u64) < cap;   // 没读满请求量 = 到文件尾
    let b64 = base64::engine::general_purpose::STANDARD.encode(&buf);
    Ok((b64, eof))
}
