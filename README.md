# InstantDrop — Ultra-Fast Local-First Wi-Fi Photo Transfer Bridge

**InstantDrop** is a zero-cloud, local-first LAN photo transfer system composed of:
1. **`laptop-receiver/`**: A lightweight, headless Rust daemon (`tokio` + `dirs`) that broadcasts UDP discovery beacons on port `45454` and streams incoming raw TCP photo payloads directly to `~/Pictures/InstantDrop` using bounded 64KB kernel buffers (`< 5 MB` RAM footprint regardless of file size).
2. **`mobile-app/`**: A sleek dark-mode Flutter mobile sender app with automatic UDP discovery, raw binary TCP socket streaming, SQLite (`sqflite`) history persistence, instant camera/gallery batch sending, and native Android/iOS OS Share Sheet integration (`receive_sharing_intent`).

---

## 1. Binary Wire Protocol Specification

- **UDP Auto-Discovery (Port `45454`):**
  - Every 2 seconds, the Laptop Receiver broadcasts:
    ```text
    INSTANT_DROP_DISCOVER:<TCP_PORT>:<DEVICE_NAME>
    ```
  - The Mobile App listens on `0.0.0.0:45454` and automatically resolves the sender's LAN IP, TCP port, and hostname.
- **TCP Binary File Stream (Default Port `45455`):**
  - For each photo, the Mobile App opens a TCP socket with `TCP_NODELAY` enabled and transmits:
    1. **`4 bytes` (`u32` Big-Endian):** Exact byte length of the UTF-8 filename (`N`).
    2. **`N bytes` (UTF-8):** The exact filename (e.g., `IMG_20261112_183000.jpg`).
    3. **Remaining bytes until EOF:** Unmodified, raw binary file stream (`file.openRead()` -> `Socket.addStream` on mobile; `tokio::io::copy` -> `BufWriter<File>` on laptop).

---

## 2. Step-by-Step Build & Run Guide

### Step 1: Open Firewall Ports on Laptop (`45454` UDP & `45455` TCP)

#### Windows (Run in Administrator PowerShell)
```powershell
New-NetFirewallRule -DisplayName "InstantDrop UDP Discovery" -Direction Outbound -Protocol UDP -LocalPort 45454 -RemotePort 45454 -Action Allow
New-NetFirewallRule -DisplayName "InstantDrop TCP Receiver" -Direction Inbound -Protocol TCP -LocalPort 45455 -Action Allow
```

#### Linux (`ufw` or `firewalld`)
```bash
# Ubuntu / Debian (UFW)
sudo ufw allow 45454/udp
sudo ufw allow 45455/tcp

# Fedora / RHEL (firewalld)
sudo firewall-cmd --permanent --add-port=45454/udp
sudo firewall-cmd --permanent --add-port=45455/tcp
sudo firewall-cmd --reload
```

---

### Step 2: Build & Run the Laptop Receiver (Rust)

```bash
cd laptop-receiver
cargo build --release
```

The optimized binary is output to:
- **Windows:** `target\release\instant-drop-receiver.exe`
- **Linux / macOS:** `target/release/instant-drop-receiver`

#### Running Silently in the Background

- **Windows (Silent Background Process / Startup):**
  1. Option A (Zero-Window Native Subsystem): Uncomment `#![windows_subsystem = "windows"]` on Line 2 of `laptop-receiver/src/main.rs` and recompile with `cargo build --release`. Double-clicking or placing a shortcut in `shell:startup` will run it completely invisibly with no console window.
  2. Option B (PowerShell Hidden Window):
     ```powershell
     Start-Process -FilePath ".\target\release\instant-drop-receiver.exe" -WindowStyle Hidden
     ```

- **Linux (`systemd` User Service):**
  Create `~/.config/systemd/user/instant-drop.service`:
  ```ini
  [Unit]
  Description=InstantDrop Wi-Fi Photo Receiver Daemon
  After=network-online.target

  [Service]
  ExecStart=%h/instant-drop-receiver
  Restart=always
  RestartSec=3

  [Install]
  WantedBy=default.target
  ```
  Enable and start:
  ```bash
  systemctl --user daemon-reload
  systemctl --user enable --now instant-drop.service
  ```

---

### Step 3: Build & Run the Mobile App (Flutter)

```bash
cd mobile-app
flutter pub get
flutter run --release
```
*(Note: If initializing into a fresh Flutter folder without generated platform runners, run `flutter create .` inside `mobile-app/` first, while keeping the provided `lib/`, `pubspec.yaml`, `android/app/src/main/AndroidManifest.xml`, and `ios/Runner/Info.plist`).*

