use std::ffi::CString;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::process::{Command, Stdio};
use anyhow::{Context, Result};
use nix::mount::{mount, MsFlags};
use serde::{Deserialize, Serialize};
use socket2::{Domain, Protocol, Socket, Type};

// VSock Constants
const VMADDR_CID_ANY: u32 = 0xFFFFFFFF; // Listen on any
const VMADDR_PORT: u32 = 5000;
const AF_VSOCK: i32 = 40; // Standard VSock Address Family

#[derive(Serialize, Deserialize, Debug)]
struct ExecutionRequest {
    cmd: String,
    args: Vec<String>,
    env: std::collections::HashMap<String, String>,
    cwd: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
struct ExecutionResult {
    exit_code: i32,
    stdout: String,
    stderr: String,
}

fn main() -> Result<()> {
    // 1. Init Phase: Prepare the Guest Environment
    setup_environment()?;

    // 2. Network Phase: Listen on VSock
    // loop to handle multiple connections? Or single shot?
    // Plan: Single shot per VM for security, then shutdown.
    // Or accept loop if we want reuse (Actuator controls lifecycle).
    // Let's do loop for robustness, but Actuator kills VM anyway.
    
    println!("[Pilot] Listening on VSock Port {}", VMADDR_PORT);
    let listener = create_vsock_listener(VMADDR_PORT)?;

    // Accept Loop
    loop {
        match listener.accept() {
            Ok((socket, addr)) => {
                println!("[Pilot] Connection from {:?}", addr);
                if let Err(e) = handle_connection(socket) {
                    eprintln!("[Pilot] Connection Error: {:?}", e);
                }
                // Determine if we should exit after one cmd?
                // For "Function-as-a-Service", yes.
                // But logging/debug might want to stay alive.
                // We'll reset and wait for next, Actuator kills us.
            }
            Err(e) => eprintln!("[Pilot] Accept Error: {:?}", e),
        }
    }
}

fn setup_environment() -> Result<()> {
    // Only perform init duties if PID 1
    if std::process::id() == 1 {
        println!("[Pilot] Running as Init process");
        
        // Mount /proc
        fs::create_dir_all("/proc").ok();
        mount(
            Some("proc"),
            "/proc",
            Some("proc"),
            MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
            None::<&str>,
        ).context("Failed to mount /proc")?;

        // Mount /sys
        fs::create_dir_all("/sys").ok();
        mount(
            Some("sysfs"),
            "/sys",
            Some("sysfs"),
            MsFlags::MS_NOSUID | MsFlags::MS_NODEV | MsFlags::MS_NOEXEC,
            None::<&str>,
        ).context("Failed to mount /sys")?;
        
        // Mount /dev if needed (devtmpfs)
        // Usually kernel mounts it or we assume minimal
        
        println!("[Pilot] Environment Initialized");
    }
    Ok(())
}

fn create_vsock_listener(port: u32) -> Result<Socket> {
    // Use socket2 for VSock
    let socket = Socket::new(Domain::from(AF_VSOCK), Type::STREAM, None)?;
    
    // Bind
    // struct sockaddr_vm {
    //    sa_family_t svm_family;
    //    unsigned short svm_reserved1;
    //    unsigned int svm_port;
    //    unsigned int svm_cid;
    //    ...
    // }
    // We construct distinct sockaddr manually or use a crate binding logic.
    // socket2 needs SockAddr.
    // Since we avoid 'vsock' crate dependency complexity for now if possible,
    // let's assume we can construct it via socket2 or unsafe.
    
    // Wait, libc::sockaddr_vm exists.
    let sockaddr = unsafe {
        let mut sa: libc::sockaddr_vm = std::mem::zeroed();
        sa.svm_family = AF_VSOCK as u16;
        sa.svm_port = port;
        sa.svm_cid = VMADDR_CID_ANY;
        
        socket2::SockAddr::init(|storage, len| {
            std::ptr::copy_nonoverlapping(
                &sa as *const _ as *const u8, 
                storage as *mut u8, 
                std::mem::size_of::<libc::sockaddr_vm>()
            );
            *len = std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t;
            Ok(())
        })?
    };

    socket.bind(&sockaddr)?;
    socket.listen(1)?; // Backlog 1
    Ok(socket)
}

fn handle_connection(socket: Socket) -> Result<()> {
    // Convert to std TcpStream-like
    let mut stream = unsafe { std::net::TcpStream::from_raw_fd(socket.into_raw_fd()) };

    // 1. Read Request JSON
    // Protocol: Length-prefixed? Or just JSON stream?
    // Let's expect simple JSON and close-on-write.
    // But reading generic JSON from stream needs framing.
    // Using newline delimiter or reading until EOF (if sender half-closes).
    
    // Simple Protocol: Sender sends JSON + '\n'.
    let mut reader = std::io::BufReader::new(stream.try_clone()?);
    
    // We read strictly line based for simplicity
    let mut line = String::new();
    use std::io::BufRead;
    reader.read_line(&mut line)?;
    
    if line.trim().is_empty() {
        return Ok(());
    }
    
    let req: ExecutionRequest = serde_json::from_str(&line).context("Invalid JSON")?;
    println!("[Pilot] Executing: {} {:?}", req.cmd, req.args);

    // 2. Execute
    let mut child = Command::new(&req.cmd)
        .args(&req.args)
        .envs(&req.env)
        .current_dir(req.cwd.unwrap_or("/".to_string()))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("Failed to spawn command")?;

    let output = child.wait_with_output()?;
    
    // 3. Send Response
    let result = ExecutionResult {
        exit_code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
    };

    let resp_json = serde_json::to_string(&result)?;
    stream.write_all(resp_json.as_bytes())?;
    stream.write_all(b"\n")?;
    
    println!("[Pilot] Finished. Exit Code: {}", result.exit_code);
    Ok(())
}
