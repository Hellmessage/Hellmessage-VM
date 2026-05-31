// exec.rs — 在 helper 的【登录用户会话】跑命令, 同步返回 exit/stdout/stderr.
//
// 仅 host→guest 控制流: helper 执行 host 给的命令 (host 是权威方). guest 不主动跑任何东西.
// powershell 走 -EncodedCommand (UTF-16LE base64): Unicode 正确 + 免 shell 转义.
// stdout/stderr 用后台线程抽干防 pipe 满死锁; 超时轮询 kill.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;

pub struct ExecResult {
    pub exit_code: i32,    // 超时 = -1
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// 跑命令. shell = "cmd" 走 cmd /c; 其它 (默认) 走 powershell -EncodedCommand.
/// timeout_ms 到 → kill + exit_code=-1. stdin 可选透传.
pub fn run(
    shell: &str,
    script: &str,
    timeout_ms: Option<u64>,
    stdin: Option<Vec<u8>>,
) -> std::io::Result<ExecResult> {
    let mut cmd = if shell == "cmd" {
        let mut c = Command::new("cmd.exe");
        c.args(["/c", script]);
        c
    } else {
        // powershell -EncodedCommand <UTF-16LE base64>
        let utf16: Vec<u8> = script.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        let enc = base64::engine::general_purpose::STANDARD.encode(&utf16);
        let mut c = Command::new("powershell.exe");
        c.args(["-NoProfile", "-NonInteractive", "-EncodedCommand", &enc]);
        c
    };
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn()?;

    // stdin: 写完即 close (EOF); 无 stdin 也要 close 防子进程等输入挂死
    if let Some(mut si) = child.stdin.take() {
        if let Some(data) = stdin {
            let _ = si.write_all(&data);
        }
        // si drop → close
    }

    // 后台抽干 stdout/stderr
    let mut so = child.stdout.take().unwrap();
    let mut se = child.stderr.take().unwrap();
    let h1 = thread::spawn(move || { let mut b = Vec::new(); let _ = so.read_to_end(&mut b); b });
    let h2 = thread::spawn(move || { let mut b = Vec::new(); let _ = se.read_to_end(&mut b); b });

    // 轮询等退出 / 超时 kill
    let deadline = timeout_ms.map(|ms| Instant::now() + Duration::from_millis(ms));
    let exit_code;
    loop {
        match child.try_wait()? {
            Some(status) => {
                exit_code = status.code().unwrap_or(-1);
                break;
            }
            None => {
                if let Some(dl) = deadline {
                    if Instant::now() >= dl {
                        let _ = child.kill();
                        let _ = child.wait();
                        exit_code = -1;   // 超时哨兵
                        break;
                    }
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
    }

    let stdout = h1.join().unwrap_or_default();
    let stderr = h2.join().unwrap_or_default();
    Ok(ExecResult { exit_code, stdout, stderr })
}
