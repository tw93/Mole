use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub enum ScriptEvent {
    Line(String),
    Finished(Result<i32, String>),
}

/// Run a bash script at the given path with arguments and environment variables,
/// streaming stdout line-by-line back through an mpsc channel.
pub fn run_script(
    script_path: &str,
    args: Vec<String>,
    envs: Vec<(String, String)>,
) -> mpsc::Receiver<ScriptEvent> {
    let (tx, rx) = mpsc::channel(256);
    let script_path = script_path.to_string();

    tokio::spawn(async move {
        let mut cmd = Command::new("bash");
        cmd.arg(&script_path);
        for arg in args {
            cmd.arg(arg);
        }
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped()); // We can read stderr too if needed, or redirect to null.

        // Load custom environment variables (e.g. MOLE_DRY_RUN, MOLE_TEST_NO_AUTH)
        for (k, v) in envs {
            cmd.env(k, v);
        }

        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                let err_msg = if e.kind() == std::io::ErrorKind::NotFound {
                    format!("Script not found: '{}' is missing. Please ensure it exists in the expected directory.", script_path)
                } else {
                    format!("Failed to execute {}: {}", script_path, e)
                };
                let _ = tx
                    .send(ScriptEvent::Finished(Err(err_msg)))
                    .await;
                return;
            }
        };

        let stdout = child.stdout.take().expect("Failed to open stdout pipe");
        let reader = BufReader::new(stdout);
        let mut lines = reader.lines();

        let tx_clone = tx.clone();
        tokio::spawn(async move {
            while let Ok(Some(line)) = lines.next_line().await {
                if tx_clone.send(ScriptEvent::Line(line)).await.is_err() {
                    break; // Channel closed
                }
            }
        });

        // Wait for process to complete
        match child.wait().await {
            Ok(exit_status) => {
                let code = exit_status.code().unwrap_or(-1);
                let _ = tx.send(ScriptEvent::Finished(Ok(code))).await;
            }
            Err(e) => {
                let _ = tx
                    .send(ScriptEvent::Finished(Err(format!(
                        "Process wait failed: {}",
                        e
                    ))))
                    .await;
            }
        }
    });

    rx
}
