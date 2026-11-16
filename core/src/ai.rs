//! AI categorization by running a local CLI: Anthropic's `claude` or OpenAI's `codex`. Nothing else.
//! The prompt contains text from bank files, so every CLI runs with its tools off, in an empty
//! temporary folder, and no shell is involved.
//! The prompt is written to the CLI's standard input and is never a command-line argument:
//! arguments can be read by every account on the computer (`ps`) while the CLI runs.
//! Nothing here holds the database lock; callers build prompts first and apply results after.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::error::{err, Result};
use crate::models::{AiStatus, AppSettings};

pub fn which(cmd: &str) -> Option<String> {
    let out = Command::new("/usr/bin/which").arg(cmd).stderr(Stdio::null()).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let p = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if p.is_empty() { None } else { Some(p) }
}

pub fn status(settings: &AppSettings) -> AiStatus {
    AiStatus {
        provider: settings.ai_provider.clone(),
        claude: which("claude"),
        codex: which("codex"),
    }
}

/// The only providers the app runs: Anthropic (claude) and OpenAI (codex). Any other name is refused.
pub const PROVIDERS: &[&str] = &["claude", "codex"];

/// Builds the CLI call. Every provider runs with its tools off (or in its read-only mode)
/// so text from a bank file can't make it read files or run commands. The prompt is not part
/// of the call; `exec` feeds it to the CLI on standard input.
fn build_command(settings: &AppSettings) -> Result<Command> {
    let provider = settings.ai_provider.as_str();
    let model = settings.ai_model.trim();
    if model.starts_with('-') {
        return err("The AI model name can't start with a dash");
    }
    Ok(match provider {
        "claude" => {
            let mut c = Command::new("claude");
            // No built-in tools, no MCP servers, no skills, nothing saved to disk.
            c.args(["--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"]);
            if !model.is_empty() {
                c.args(["--model", model]);
            }
            // -p with no prompt reads it from standard input.
            c.args(["-p", "--output-format", "text"]);
            c
        }
        "codex" => {
            let mut c = Command::new("codex");
            // Read-only sandbox: no writes, no network. The working folder is not a git repo.
            c.args(["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral"]);
            if !model.is_empty() {
                c.args(["-m", model]);
            }
            // "-" in place of the prompt: read it from standard input.
            c.arg("-");
            c
        }
        other => return err(format!("Unknown AI provider \"{other}\". Choose one in Settings.")),
    })
}

/// An empty private folder for one CLI run, removed afterwards. The CLIs treat their
/// working folder as the project, so it must not be the home folder.
struct WorkDir(std::path::PathBuf);

impl WorkDir {
    fn new() -> Result<Self> {
        let path = std::env::temp_dir().join(format!("ledgerline-ai-{}", crate::db::uid()));
        let mut b = std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            b.mode(0o700);
        }
        b.create(&path)?;
        Ok(WorkDir(path))
    }
}

impl Drop for WorkDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub fn run(settings: &AppSettings, prompt: &str) -> Result<String> {
    let cmd = build_command(settings)?;
    exec(cmd, prompt, &settings.ai_provider, settings.ai_timeout_sec)
}

/// Runs the CLI in an empty private folder, gives it `input` on standard input, and returns
/// what it printed.
fn exec(mut cmd: Command, input: &str, provider: &str, timeout_sec: u32) -> Result<String> {
    let work = WorkDir::new()?;
    cmd.current_dir(&work.0);
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| crate::error::LedgerError::Message {
        msg: format!("Could not start the {provider} CLI: {e}. Check that it is installed and on your PATH."),
    })?;

    // Write the input on its own thread, then close the pipe so the CLI sees the end of it.
    // A CLI that quits without reading everything is reported through its exit status below.
    let mut si = child.stdin.take().unwrap();
    let input = input.as_bytes().to_vec();
    let in_t = std::thread::spawn(move || {
        let _ = si.write_all(&input);
    });

    // Drain pipes on threads so a chatty CLI can't block on a full pipe.
    let mut so = child.stdout.take().unwrap();
    let mut se = child.stderr.take().unwrap();
    let out_t = std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = so.read_to_end(&mut b);
        b
    });
    let err_t = std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = se.read_to_end(&mut b);
        b
    });
    let timeout = Duration::from_secs(timeout_sec.max(10) as u64);
    let start = Instant::now();
    let status = loop {
        if let Some(s) = child.try_wait()? {
            break s;
        }
        if start.elapsed() > timeout {
            let _ = child.kill();
            let _ = child.wait();
            return err(format!("{provider} CLI timed out after {}s", timeout.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    let _ = in_t.join();
    let stdout = String::from_utf8_lossy(&out_t.join().unwrap_or_default()).to_string();
    let stderr = String::from_utf8_lossy(&err_t.join().unwrap_or_default()).to_string();
    if !status.success() {
        let tail: String = stderr.trim().chars().rev().take(500).collect::<Vec<_>>().into_iter().rev().collect();
        return err(format!("{provider} CLI failed: {}", if tail.is_empty() { status.to_string() } else { tail }));
    }
    Ok(stdout)
}

fn strip_fences(text: &str) -> String {
    let re = regex::Regex::new(r"(?i)```(?:json)?").unwrap();
    re.replace_all(text, "").trim().to_string()
}

pub fn extract_json_array(text: &str) -> Result<Vec<Value>> {
    if text.trim().is_empty() {
        return err("Empty response from AI");
    }
    let t = strip_fences(text);
    match (t.find('['), t.rfind(']')) {
        (Some(s), Some(e)) if e > s => match serde_json::from_str::<Value>(&t[s..=e])? {
            Value::Array(a) => Ok(a),
            _ => err("No JSON array found in AI response"),
        },
        _ => err("No JSON array found in AI response"),
    }
}

pub fn extract_json_object(text: &str) -> Result<Value> {
    let t = strip_fences(text);
    match (t.find('{'), t.rfind('}')) {
        (Some(s), Some(e)) if e > s => Ok(serde_json::from_str(&t[s..=e])?),
        _ => err("No JSON found in AI response"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_fenced_json() {
        let a = extract_json_array("Sure!\n```json\n[{\"id\":\"1\"}]\n```").unwrap();
        assert_eq!(a.len(), 1);
        assert!(extract_json_array("nope").is_err());
    }

    fn settings(provider: &str) -> AppSettings {
        AppSettings { currency: "USD".into(), theme: "dark".into(), ai_provider: provider.into(), ai_model: String::new(), ai_timeout_sec: 30 }
    }

    fn argv(c: &Command) -> Vec<String> {
        std::iter::once(c.get_program()).chain(c.get_args()).map(|a| a.to_string_lossy().into_owned()).collect()
    }

    #[test]
    fn clis_run_with_tools_off() {
        let claude = argv(&build_command(&settings("claude")).unwrap());
        assert_eq!(&claude[..3], ["claude", "--tools", ""]);
        assert!(claude.contains(&"--strict-mcp-config".to_string()));
        let codex = argv(&build_command(&settings("codex")).unwrap());
        assert!(codex.windows(2).any(|w| w == ["--sandbox", "read-only"]));
        assert!(codex.contains(&"--skip-git-repo-check".to_string()));
    }

    #[test]
    fn only_claude_and_codex_are_run() {
        for other in ["zcode", "opencode", "custom", "something-else", ""] {
            let e = build_command(&settings(other)).unwrap_err();
            assert!(e.to_string().contains("Unknown AI provider"), "{other}");
        }
        let mut s = settings("claude");
        s.ai_model = "--dangerously-skip-permissions".into();
        assert!(build_command(&s).is_err());
    }

    /// Arguments are visible to every account on the computer, so the prompt must not be one.
    #[test]
    fn the_prompt_goes_in_on_stdin_not_as_an_argument() {
        // Each CLI is told to read standard input: claude by -p with nothing after it, codex by "-".
        let claude = argv(&build_command(&settings("claude")).unwrap());
        assert_eq!(&claude[claude.len() - 3..], ["-p", "--output-format", "text"]);
        let codex = argv(&build_command(&settings("codex")).unwrap());
        assert_eq!(codex.last().unwrap(), "-");

        // And what is written there arrives whole, including more than a pipe holds at once.
        let prompt = format!("ACME CORP | 12.00\n{}", "x".repeat(300_000));
        let out = exec(Command::new("/bin/cat"), &prompt, "test", 30).unwrap();
        assert_eq!(out, prompt);
    }

    #[test]
    fn a_cli_that_ignores_its_input_still_finishes() {
        let mut c = Command::new("/bin/sh");
        c.args(["-c", "echo done"]);
        let out = exec(c, &"x".repeat(300_000), "test", 30).unwrap();
        assert_eq!(out.trim(), "done");
    }

    #[test]
    fn runs_in_an_empty_private_folder_that_is_removed() {
        let mut c = Command::new("/bin/sh");
        c.args(["-c", "pwd; ls -A | wc -l"]);
        let out = exec(c, "", "test", 30).unwrap();
        let mut lines = out.lines();
        let dir = lines.next().unwrap().to_string();
        assert!(dir.contains("ledgerline-ai-"), "{dir}");
        assert_eq!(lines.next().unwrap().trim(), "0");
        assert!(!std::path::Path::new(&dir).exists());
    }

}
