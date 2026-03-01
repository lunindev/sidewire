# MacDisplay

**Use a second MacBook as an external display for your primary Mac — no dongle, no third-party drivers.**

MacDisplay creates a virtual monitor on the sender Mac, captures its screen content via ScreenCaptureKit, encodes it with hardware-accelerated HEVC, and streams it over the network to a receiver Mac that decodes and displays the video in real time. Mouse and keyboard input on the receiver is forwarded back to the sender, so you can interact with the virtual display naturally.

Works over **Wi-Fi** or **Thunderbolt** (direct cable connection between two Macs).

---

## How It Works

```
┌─────────────────── Mac 1 (Sender) ───────────────────┐
│                                                       │
│  CGVirtualDisplay ──► ScreenCaptureKit ──► HEVC Encoder │
│        ▲                                      │       │
│        │ Input Injection              TCP/IP  │       │
│        │                                      ▼       │
└────────┼──────────────────────────────────────────────┘
         │                                      │
         │            Network (Wi-Fi / TB)      │
         │                                      │
┌────────┼──────────────────────────────────────────────┐
│        │                                      ▼       │
│  Input Capture ◄── Keyboard/Mouse    HEVC Decoder     │
│                                          │            │
│                              AVSampleBufferDisplayLayer│
│                                                       │
└─────────────────── Mac 2 (Receiver) ─────────────────┘
```

### Key Features

- **Virtual display** — creates a real display in macOS (visible in Display Settings) using private `CGVirtualDisplay` API, with HiDPI support
- **Hardware HEVC encoding/decoding** — low-latency H.265 via VideoToolbox
- **Adaptive bitrate** — automatically adjusts encoding bitrate (5–50 Mbps) based on network conditions
- **Input forwarding** — mouse, keyboard, and scroll events captured on the receiver are injected on the sender
- **Auto-discovery** — Bonjour service discovery to find receivers on the local network
- **Interface selection** — choose a specific network interface (Wi-Fi, Thunderbolt, Ethernet) or let the OS decide
- **Multiple resolutions** — preset options from 1280x800 to 3456x2234 (Retina), plus automatic matching to receiver's native display
- **30/60 FPS** — configurable frame rate
- **Fullscreen immersive mode** — receiver auto-enters fullscreen on connection, ESC to exit

---

## Requirements

| | Sender (Mac 1) | Receiver (Mac 2) |
|---|---|---|
| **macOS** | 14.0 (Sonoma) or later | 14.0 (Sonoma) or later |
| **Xcode** | 16.0+ | — |
| **Connection** | Wi-Fi (same network) or Thunderbolt cable | same |

> Both Macs need to be Apple Silicon or Intel — any Mac running macOS 14+.

---

## Building from Source

### 1. Clone the repository

```bash
git clone https://github.com/YOUR_USERNAME/macdisplay.git
cd macdisplay
```

### 2. Generate the Xcode project (optional)

The repo includes a pre-generated `MacDisplay.xcodeproj`. If you need to regenerate it (e.g., after modifying `project.yml`):

```bash
brew install xcodegen
xcodegen generate
```

### 3. Open in Xcode

```bash
open MacDisplay.xcodeproj
```

### 4. Build and run

The project contains **two targets**:

| Target | Run on | Purpose |
|---|---|---|
| **SenderApp** | Your primary Mac (the one with the content) | Creates a virtual display and streams it |
| **ReceiverApp** | Your secondary Mac (used as the monitor) | Receives and displays the stream |

1. Select the **SenderApp** scheme and click **Run** (or `Cmd+R`)
2. Select the **ReceiverApp** scheme and click **Run** on the second Mac
3. Both apps are unsigned (`CODE_SIGNING_ALLOWED = NO`), so they run directly from Xcode without a developer certificate

> **Note:** SenderApp will request **Screen Recording** permission on first launch. Grant it in System Settings → Privacy & Security → Screen Recording.

---

## Usage

### Quick Start

1. **Launch ReceiverApp** on the Mac you want to use as a display — it will start listening automatically
2. **Launch SenderApp** on your primary Mac
3. **Connect:**
   - **Auto-discover** mode: switch to "Auto-discover", the receiver should appear in the list — click "Connect"
   - **Manual IP** mode: enter the receiver's IP address and click "Connect"
4. The virtual display is created automatically, streaming starts, and the receiver enters fullscreen

### Sender Controls

- **Connection mode** — Manual IP or Auto-discover (Bonjour)
- **Interface** — choose a specific network interface or "Any"
- **Resolution** — pick from presets or auto-match the receiver's native resolution
- **FPS** — 30 or 60 frames per second
- **Virtual display** — toggle between streaming the virtual display or a physical one
- **Adaptive bitrate** — auto-adjusts encoding quality based on network throughput

### Receiver Controls

- **Double-click** — toggle the stats overlay (FPS, latency, bitrate)
- **ESC** — exit fullscreen / immersive mode
- **Interface picker** — shown on the waiting screen, choose which interface to listen on

---

## Connecting via Thunderbolt

For the lowest latency, connect both Macs with a Thunderbolt cable:

1. Connect the cable between both Macs
2. Open **System Settings → Network** on both Macs — verify "Thunderbolt Bridge" shows a self-assigned IP (169.254.x.x)
3. In SenderApp, enter the receiver's Thunderbolt Bridge IP in Manual IP mode
4. Optionally select the Thunderbolt interface in the Interface picker

> **VPN note:** If you have a VPN active, it may interfere with routing to 169.254.x.x addresses. Either disconnect the VPN or add an explicit route:
> ```bash
> sudo route add -host <RECEIVER_THUNDERBOLT_IP> -interface bridge0
> ```

---

## Project Structure

```
MacDisplay/
├── SenderApp/
│   ├── SenderApp.swift              — App entry point
│   ├── SenderView.swift             — Main UI
│   ├── NetworkSender.swift          — TCP client, Bonjour browser
│   ├── ScreenCapture.swift          — ScreenCaptureKit wrapper
│   ├── VideoEncoder.swift           — HEVC hardware encoder
│   ├── VirtualDisplay.swift         — CGVirtualDisplay management
│   ├── InputInjector.swift          — CGEvent-based input injection
│   └── CGVirtualDisplayPrivate.h    — Private API headers
├── ReceiverApp/
│   ├── ReceiverApp.swift            — App entry point
│   ├── ReceiverView.swift           — Main UI (fullscreen video)
│   ├── NetworkReceiver.swift        — TCP server, Bonjour service
│   ├── VideoDecoder.swift           — HEVC hardware decoder
│   ├── DisplayWindow.swift          — AVSampleBufferDisplayLayer view
│   └── InputCapture.swift           — NSEvent-based input capture
├── Shared/
│   └── Protocol.swift               — Packet format, types, interface monitor
└── project.yml                      — XcodeGen project spec
```

---

## Protocol

Communication uses a simple binary protocol over TCP (port 5005):

| Field | Size | Description |
|---|---|---|
| `dataSize` | 4 bytes | Payload size (big-endian) |
| `timestampMs` | 8 bytes | Sender timestamp in ms (big-endian) |
| `type` | 1 byte | Packet type |

Packet types: `videoFrame` (1), `keyFrame` (2), `displayInfo` (4), `inputEvent` (5).

Video data is raw HEVC NAL units with Annex B start codes.

---

## License

[MIT](LICENSE)
