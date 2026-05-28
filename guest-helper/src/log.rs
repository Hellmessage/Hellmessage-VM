// log.rs — 简单文件日志.
//
// 写 %LOCALAPPDATA%\HVM\helper.log (滚动 10 MB).
//
// 没用 env_logger / tracing 这类大日志框架, 体积省 ~300 KB; helper 体量极小, 自家写
// 一个 print 到文件就够.

use std::fs::{create_dir_all, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::SystemTime;

const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;  // 10 MB

static LOG_STATE: Mutex<Option<LogState>> = Mutex::new(None);

struct LogState {
    path: PathBuf,
}

/// 初始化日志. 应在 main 早期调一次.
pub fn init() -> io::Result<()> {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"));
    let dir = base.join("HVM");
    create_dir_all(&dir)?;
    let path = dir.join("helper.log");

    // 滚动: 超过 MAX_LOG_BYTES 直接 rename → .old (留一份), 新文件从 0
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() > MAX_LOG_BYTES {
            let old = path.with_extension("log.old");
            let _ = std::fs::remove_file(&old);
            let _ = std::fs::rename(&path, &old);
        }
    }

    let mut state = LOG_STATE.lock().unwrap();
    *state = Some(LogState { path });
    Ok(())
}

pub fn write(line: &str) {
    if let Ok(state) = LOG_STATE.lock() {
        if let Some(s) = state.as_ref() {
            if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&s.path) {
                let ts = format_ts();
                let _ = writeln!(f, "{} {}", ts, line);
            }
        }
    }
}

fn format_ts() -> String {
    // 简化 ISO8601: 不引 chrono. UNIX 秒 + ms.
    match SystemTime::now().duration_since(SystemTime::UNIX_EPOCH) {
        Ok(d) => format!("{}.{:03}", d.as_secs(), d.subsec_millis()),
        Err(_) => "?.?".to_string(),
    }
}

/// 等效 println! 但走 helper.log.
#[macro_export]
macro_rules! hvmlog {
    ($($arg:tt)*) => {
        $crate::log::write(&format!($($arg)*))
    };
}
