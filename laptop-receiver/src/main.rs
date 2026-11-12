// Uncomment the attribute below when compiling a completely silent background executable on Windows:
// #![windows_subsystem = "windows"]

use std::error::Error;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::fs::{self, File};
use tokio::io::{self, AsyncReadExt, BufWriter};
use tokio::net::{TcpListener, TcpStream, UdpSocket};

const UDP_DISCOVERY_PORT: u16 = 45454;
const DEFAULT_TCP_PORT: u16 = 45455;
const MAX_FILENAME_LEN: usize = 1024;
const BEACON_INTERVAL_SECS: u64 = 2;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let tcp_port = std::env::var("INSTANT_DROP_PORT")
        .ok()
        .and_then(|v| v.parse::<u16>().ok())
        .unwrap_or(DEFAULT_TCP_PORT);

    let save_dir = resolve_save_directory().await?;
    let save_dir = Arc::new(save_dir);

    let device_name = hostname::get()
        .ok()
        .and_then(|h| h.into_string().ok())
        .unwrap_or_else(|| "Laptop-PC".to_string())
        .replace(':', "-");

    let local_ip = local_ip_address::local_ip()
        .map(|ip| ip.to_string())
        .unwrap_or_else(|_| "0.0.0.0".to_string());

    println!("==========================================================");
    println!("  InstantDrop Receiver v1.0.0 (Headless Rust Daemon)");
    println!("==========================================================");
    println!("[READY] Device Name  : {}", device_name);
    println!("[READY] Local IP     : {}", local_ip);
    println!("[READY] Listening on : 0.0.0.0:{} (TCP) | UDP Beacon: {}", tcp_port, UDP_DISCOVERY_PORT);
    println!("[READY] Save Folder  : {}", save_dir.display());
    println!("----------------------------------------------------------");

    let udp_task = run_udp_broadcaster(tcp_port, device_name);
    let tcp_task = run_tcp_listener(tcp_port, save_dir);

    let (udp_res, tcp_res) = tokio::join!(udp_task, tcp_task);
    if let Err(e) = udp_res {
        eprintln!("[ERROR] UDP Broadcaster terminated: {}", e);
    }
    if let Err(e) = tcp_res {
        eprintln!("[ERROR] TCP Listener terminated: {}", e);
    }

    Ok(())
}

/// Locates `C:\Users\QS\Desktop\detectmoney\my_photos` (or `INSTANT_DROP_DIR` if set) and creates it if it doesn't exist.
async fn resolve_save_directory() -> Result<PathBuf, Box<dyn Error>> {
    let target_dir = if let Ok(custom_dir) = std::env::var("INSTANT_DROP_DIR") {
        PathBuf::from(custom_dir)
    } else if cfg!(target_os = "windows") {
        PathBuf::from(r"C:\Users\QS\Desktop\detectmoney\my_photos")
    } else {
        let base_dir = dirs::desktop_dir()
            .or_else(dirs::home_dir)
            .unwrap_or_else(|| PathBuf::from("."));
        base_dir.join("detectmoney").join("my_photos")
    };
    fs::create_dir_all(&target_dir).await?;
    Ok(target_dir)
}

/// Broadcasts `INSTANT_DROP_DISCOVER:<TCP_PORT>:<DEVICE_NAME>` every 2 seconds on UDP port 45454.
async fn run_udp_broadcaster(
    tcp_port: u16,
    device_name: String,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let socket = UdpSocket::bind("0.0.0.0:0").await?;
    socket.set_broadcast(true)?;

    let payload = format!("INSTANT_DROP_DISCOVER:{}:{}", tcp_port, device_name);
    let payload_bytes = payload.as_bytes();
    let global_broadcast: SocketAddr = format!("255.255.255.255:{}", UDP_DISCOVERY_PORT).parse()?;

    let mut interval = tokio::time::interval(Duration::from_secs(BEACON_INTERVAL_SECS));

    loop {
        interval.tick().await;

        // 1. Send to global broadcast 255.255.255.255:45454
        let _ = socket.send_to(payload_bytes, global_broadcast).await;

        // 2. Also send to directed subnet broadcast (e.g. 192.168.1.255:45454) for routers/OSes
        //    that filter global broadcast across multi-interface hosts (such as Windows with WSL/Hyper-V).
        if let Ok(std::net::IpAddr::V4(ipv4)) = local_ip_address::local_ip() {
            let octets = ipv4.octets();
            let subnet_broadcast = SocketAddr::from((
                [octets[0], octets[1], octets[2], 255],
                UDP_DISCOVERY_PORT,
            ));
            if subnet_broadcast != global_broadcast {
                let _ = socket.send_to(payload_bytes, subnet_broadcast).await;
            }
        }
    }
}

/// Listens for incoming TCP connections and spawns an async stream task per file.
async fn run_tcp_listener(
    tcp_port: u16,
    save_dir: Arc<PathBuf>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let bind_addr = format!("0.0.0.0:{}", tcp_port);
    let listener = TcpListener::bind(&bind_addr).await?;

    loop {
        let (stream, peer_addr) = listener.accept().await?;
        let dir_clone = Arc::clone(&save_dir);

        tokio::spawn(async move {
            if let Err(e) = handle_incoming_file(stream, peer_addr, dir_clone).await {
                eprintln!("[ERROR] Transfer from {} failed: {}", peer_addr, e);
            }
        });
    }
}

/// Handles a single photo transfer stream adhering strictly to the binary protocol:
/// - 4 bytes (u32 Big-Endian): Filename byte length `N`
/// - `N` bytes (UTF-8): Exact filename
/// - Remaining bytes until EOF: Raw binary payload streamed directly to disk via `tokio::io::copy`
async fn handle_incoming_file(
    mut stream: TcpStream,
    peer_addr: SocketAddr,
    save_dir: Arc<PathBuf>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let start_time = Instant::now();
    let _ = stream.set_nodelay(true);

    // 1. Read 4-byte Big-Endian filename length
    let name_len = stream.read_u32().await? as usize;
    if name_len == 0 || name_len > MAX_FILENAME_LEN {
        return Err(format!("Invalid filename length: {} bytes", name_len).into());
    }

    // 2. Read N-byte UTF-8 filename
    let mut name_buf = vec![0u8; name_len];
    stream.read_exact(&mut name_buf).await?;
    let raw_filename = String::from_utf8(name_buf)?;

    // Sanitize filename to prevent path traversal and invalid OS characters
    let sanitized_name = sanitize_filename(&raw_filename);

    // Resolve collision-free path (e.g., IMG_001.jpg -> IMG_001_1.jpg)
    let dest_path = resolve_unique_filepath(&save_dir, &sanitized_name).await;
    let final_filename = dest_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(&sanitized_name)
        .to_string();

    // 3. Stream remaining TCP payload directly to disk with bounded 64KB buffer (<5MB RAM)
    let file = File::create(&dest_path).await?;
    let mut writer = BufWriter::with_capacity(64 * 1024, file);

    let bytes_copied = io::copy(&mut stream, &mut writer).await?;
    use tokio::io::AsyncWriteExt;
    writer.flush().await?;

    let elapsed = start_time.elapsed();
    let size_mb = (bytes_copied as f64) / (1024.0 * 1024.0);
    let elapsed_ms = elapsed.as_millis();

    println!(
        "[RECEIVED] {} ({:.2} MB in {}ms) from {}",
        final_filename,
        size_mb,
        elapsed_ms,
        peer_addr.ip()
    );

    Ok(())
}

/// Strips directory components and replaces illegal filesystem characters.
fn sanitize_filename(raw: &str) -> String {
    let base = Path::new(raw)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("photo.jpg");

    let cleaned: String = base
        .chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' | '\0' => '_',
            _ => c,
        })
        .collect();

    if cleaned.trim().is_empty() {
        "photo.jpg".to_string()
    } else {
        cleaned
    }
}

/// Ensures existing files are never overwritten by appending `_1`, `_2`, etc. before the extension.
async fn resolve_unique_filepath(dir: &Path, filename: &str) -> PathBuf {
    let initial = dir.join(filename);
    if !fs::try_exists(&initial).await.unwrap_or(false) {
        return initial;
    }

    let path_obj = Path::new(filename);
    let stem = path_obj
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("photo");
    let ext = path_obj.extension().and_then(|e| e.to_str());

    let mut counter = 1u32;
    loop {
        let candidate_name = match ext {
            Some(e) if !e.is_empty() => format!("{}_{}.{}", stem, counter, e),
            _ => format!("{}_{}", stem, counter),
        };
        let candidate_path = dir.join(candidate_name);
        if !fs::try_exists(&candidate_path).await.unwrap_or(false) {
            return candidate_path;
        }
        counter += 1;
    }
}

