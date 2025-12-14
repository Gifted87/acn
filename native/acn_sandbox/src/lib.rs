use rustler::{Encoder, Env, Term, NifResult};
use std::os::unix::net::UnixStream;
use std::io::{Write, BufReader, BufRead};
use serde_json::json;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use anyhow::{Context, Result, anyhow};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        timeout,
        vm_error,
        connect_error,
    }
}

#[derive(Serialize)]
struct ExecutionRequest {
    cmd: String,
    args: Vec<String>,
    env: std::collections::HashMap<String, String>,
    cwd: Option<String>,
}

#[derive(Deserialize, Debug)]
struct ExecutionResult {
    exit_code: i32,
    stdout: String,
    stderr: String,
}

#[rustler::nif]
fn run_cmd(env: Env, socket_path: String, command: String, args: Vec<String>) -> NifResult<Term> {
    match run_firecracker_sequence(&socket_path, command, args) {
        Ok(output) => Ok((atoms::ok(), output.stdout, output.stderr, output.exit_code).encode(env)),
        Err(e) => Ok((atoms::error(), format!("{:#}", e)).encode(env))
    }
}

fn run_firecracker_sequence(socket_path: &str, cmd: String, args: Vec<String>) -> Result<ExecutionResult> {
    // 1. Wait for Control Socket (Firecracker might take ms to bind)
    let mut control_stream = wait_for_socket(socket_path, Duration::from_millis(1000))
        .context("Failed to connect to Firecracker API")?;

    // 2. Configure VM
    configure_vm(&mut control_stream)?;

    // 3. Configure Network (VSock)
    let vsock_path = format!("{}.vsock", socket_path);
    configure_vsock(&mut control_stream, &vsock_path)?;

    // 4. Start Instance
    http_request(&mut control_stream, "PUT", "/actions", json!({
        "action_type": "InstanceStart"
    }))?;

    // 5. Connect to Data Plane (VSock Proxy)
    // Host connects to the Unix socket that Firecracker created for VSock
    // Retry loop as VM boots
    let mut data_stream = wait_for_socket(&vsock_path, Duration::from_millis(5000))
        .context("Failed to connect to Pilot (VSock)")?;

    // 6. Send Command
    let req = ExecutionRequest {
        cmd,
        args,
        env: std::collections::HashMap::new(), // Pass env later?
        cwd: Some("/root".to_string()),
    };
    
    let req_json = serde_json::to_string(&req)?;
    data_stream.write_all(req_json.as_bytes())?;
    data_stream.write_all(b"\n")?; // Delimiter

    // 7. Read Response
    let mut reader = BufReader::new(data_stream);
    let mut line = String::new();
    reader.read_line(&mut line).context("Failed to read from Pilot")?;
    
    if line.trim().is_empty() {
        return Err(anyhow!("Pilot returned empty response"));
    }

    let result: ExecutionResult = serde_json::from_str(&line)
        .context("Invalid JSON from Pilot")?;

    Ok(result)
}

fn configure_vm(stream: &mut UnixStream) -> Result<()> {
    // Machine Config
    http_request(stream, "PUT", "/machine-config", json!({
        "vcpu_count": 1,
        "mem_size_mib": 128
    }))?;

    // Boot Source
    http_request(stream, "PUT", "/boot-source", json!({
        "kernel_image_path": "priv/vmlinux",
        "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
    }))?;

    // RootFS
    http_request(stream, "PUT", "/drives/rootfs", json!({
        "drive_id": "rootfs",
        "path_on_host": "priv/rootfs.ext4",
        "is_root_device": true,
        "is_read_only": false
    }))?;
    
    Ok(())
}

fn configure_vsock(stream: &mut UnixStream, uds_path: &str) -> Result<()> {
    http_request(stream, "PUT", "/vsock", json!({
        "guest_cid": 3,
        "uds_path": uds_path
    }))
}

fn http_request(stream: &mut UnixStream, method: &str, path: &str, body: serde_json::Value) -> Result<()> {
    let body_str = body.to_string();
    let request = format!(
        "{} {} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\nContent-Type: application/json\r\n\r\n{}",
        method, path, body_str.len(), body_str
    );
    stream.write_all(request.as_bytes())?;
    
    // Read Response Status
    // Minimal parser
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut status_line = String::new();
    reader.read_line(&mut status_line)?;
    
    if !status_line.contains("204") && !status_line.contains("200") {
         // Read body for error?
         return Err(anyhow!("Firecracker API Error: {}", status_line.trim()));
    }
    
    // Drain headers? For persistent connection reuse, yes.
    // But here we rely on short lived or firecracker tolerating?
    // Let's drain until empty line
    for line in reader.lines() {
        if line?.trim().is_empty() { break; }
    }
    
    Ok(())
}

fn wait_for_socket(path: &str, timeout: Duration) -> Result<UnixStream> {
    let start = std::time::Instant::now();
    loop {
        if let Ok(stream) = UnixStream::connect(path) {
            return Ok(stream);
        }
        if start.elapsed() > timeout {
            return Err(anyhow!("Timeout waiting for socket {}", path));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[rustler::nif]
fn count_tokens_nif(text: String) -> NifResult<usize> {
    let bpe = tiktoken_rs::cl100k_base().map_err(|_| rustler::Error::Term(Box::new("Failed to load tokenizer")))?;
    let tokens = bpe.encode_with_special_tokens(&text);
    Ok(tokens.len())
}

rustler::init!("Elixir.ACN.Actuator.RustlerBridge", [run_cmd, count_tokens_nif]);
