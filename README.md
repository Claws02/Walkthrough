# ScanCapture — Mobile 3D Scene Reconstruction

Transform your iPhone into a professional 3D scanner. Capture a room or object, upload to your self-hosted server, and explore a photorealistic 3D Gaussian Splat in seconds.

---

## How It Works

**Option A — No app needed: browser upload (works on any iPhone)**
```
iPhone Safari  →  http://YOUR_SERVER_IP
  │
  ├─ Record standard .mp4 / .mov with Camera app
  └─ Upload via web page (drag-drop or tap)
            │
            ▼
Backend Server (Docker)
  │
  ├─ FFmpeg extracts ~150 frames from video
  ├─ COLMAP recovers camera poses via SfM
  ├─ Nerfstudio `splatfacto` trains 3D Gaussian Splat
  └─ Exports .ply
            │
            ▼
Browser Viewer (same page, WebGL 2)
  └─ Interactive 3D Gaussian Splat — orbit, pan, zoom
```

**Option B — Native iOS app (ARKit + LiDAR, best quality)**
```
iPhone (ScanCapture app)
  │
  ├─ ARKit + LiDAR records frames at 5 FPS
  ├─ Camera pose (4×4 matrix) logged via VIO — skips COLMAP
  ├─ Depth map saved alongside each image
  └─ Packaged as a ZIP → uploaded to your server
            │
            ▼
Backend Server (Docker)
  │
  ├─ Uses existing ARKit transforms directly (no COLMAP needed)
  ├─ Nerfstudio `splatfacto` trains 3D Gaussian Splat
  └─ Exports .ply → notifies app
            │
            ▼
In-app Viewer
  └─ WebGL renderer displays interactive 3D scene
     (orbit, pan, zoom — 60+ FPS on iPhone 12 Pro+)
```

**Technology stack:**
| Layer | Technology |
|---|---|
| Mobile capture | Swift + ARKit + LiDAR (iOS 17+) |
| Camera pose | Apple VIO (Visual-Inertial Odometry) |
| Scene reconstruction | 3D Gaussian Splatting (3DGS) |
| SfM fallback | COLMAP |
| Training framework | Nerfstudio `splatfacto` + gsplat |
| Rendering | Custom WebGL 2 splat renderer |
| Backend API | FastAPI + SQLAlchemy + SQLite |
| Job queue | Celery + Redis |
| Deployment | Docker Compose |

---

## Repository Layout

```
├── ios/                     Native iOS app (Swift + SwiftUI)
│   ├── project.yml          XcodeGen project definition
│   └── ScanCapture/
│       ├── Capture/         ARKit session + LiDAR manager
│       ├── Models/          Data models, settings
│       ├── Network/         API client, upload manager
│       ├── Views/           All SwiftUI views
│       └── Resources/       Info.plist, viewer.html (WebGL)
│
├── web/                     Browser upload UI + WebGL viewer (no app needed)
│   ├── index.html           Mobile-first upload & job tracking page
│   └── viewer.html          WebGL 2 Gaussian splat renderer
│
├── backend/                 Self-hosted processing server
│   ├── docker-compose.yml   Orchestrates all services
│   ├── api/                 FastAPI REST service
│   └── worker/              Celery GPU worker (FFmpeg + COLMAP + Nerfstudio)
│
├── viewer/                  Standalone web viewer (works in any browser)
│   └── index.html           Drop-in WebGL 2 Gaussian splat renderer
│
└── setup.sh                 One-command setup script
```

---

## Requirements

### Server
| Requirement | Minimum | Recommended |
|---|---|---|
| OS | Ubuntu 22.04 | Ubuntu 22.04 |
| GPU | NVIDIA GTX 1080 | NVIDIA RTX 3090 / 4090 |
| VRAM | 8 GB | 24 GB |
| RAM | 16 GB | 32 GB |
| Disk | 50 GB | 200 GB |
| Docker | 24.x + Compose v2 | latest |
| NVIDIA drivers | 525+ | latest |
| NVIDIA Container Toolkit | required | required |

> **No GPU?** The server will fall back to CPU training, but a 30 000-iteration session takes 4–8 hours instead of 20–45 minutes.

### iPhone
- iPhone with LiDAR: iPhone 12 Pro / 13 / 14 / 15 Pro (all models)
- OR any iPhone XR or later (camera-only mode, no depth seeding)
- iOS 17.0 or later
- ~500 MB free storage per scan session

### Development machine (to build the app)
- macOS 14 Sonoma or later
- Xcode 15.4 or later
- Apple Developer account (free works for personal device)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

---

## Quick Start

### Step 1 — Set up the server

```bash
git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd YOUR_REPO

# Install NVIDIA Container Toolkit (if not already installed)
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

# Build and start all services
cd backend
cp .env.example .env
# Edit .env if needed (default settings work for local use)
docker compose up -d --build

# Watch logs
docker compose logs -f
```

The web UI is available at `http://YOUR_SERVER_IP` — open it in iPhone Safari to upload videos directly.  
API docs: `http://YOUR_SERVER_IP/api/docs`.

### Step 2a — Use from iPhone Safari (no Xcode needed)

1. Open `http://YOUR_SERVER_IP` in Safari on your iPhone
2. Tap **Upload Scan** and select a video from your Camera Roll (`.mp4` or `.mov`)
3. The page shows upload progress and polls for job status automatically
4. When processing completes, tap **View in 3D** to open the splat in the browser viewer

**Tips for best results with standard video:**
- Film slowly and steadily — fast motion blurs frames and confuses COLMAP
- Circle the subject 2–3 times at different heights
- Avoid pointing directly at featureless white walls
- 20–60 second clips work well (~150 frames extracted)

### Step 2b — Build the iOS app (optional, best quality)

```bash
# Install XcodeGen (macOS only)
brew install xcodegen

# Generate the Xcode project
cd ios
xcodegen generate

# Open in Xcode
open ScanCapture.xcodeproj
```

In Xcode:
1. Select the `ScanCapture` target
2. Under **Signing & Capabilities** → choose your development team
3. In `ios/ScanCapture/Models/AppSettings.swift`, set the default `serverURL` to `http://YOUR_SERVER_IP:8000`
4. Connect your iPhone via USB
5. Press **Run** (⌘R) or build to TestFlight for wireless distribution

### Step 3 — Scan and explore

1. Open the app → tap **Capture**
2. Slowly pan your iPhone around the scene (10–30 seconds, 3–5 m/s panning speed)
3. Tap **Stop & Upload** when done
4. Watch the **Jobs** tab — processing takes 5–45 minutes depending on scene size
5. Tap the completed job → **View in 3D**

---

## Server Configuration

All server settings are in `backend/.env` (copied from `.env.example`):

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | SQLite | Path to job database |
| `REDIS_URL` | `redis://redis:6379/0` | Redis broker URL |
| `UPLOAD_DIR` | `/data/uploads` | Where ZIPs are stored |
| `RESULTS_DIR` | `/data/results` | Where .ply files are stored |
| `MAX_UPLOAD_SIZE_MB` | `1024` | Max upload file size (supports long videos) |
| `NERFSTUDIO_MAX_ITERATIONS` | `30000` | Training iterations (quality vs speed) |
| `COLMAP_GPU_INDEX` | `0` | GPU index for COLMAP, `-1` = all |

**Training quality presets:**

| Preset | Iterations | Time (RTX 4090) | Quality |
|---|---|---|---|
| Quick preview | 5 000 | ~3 min | Low |
| Standard | 30 000 | ~20 min | Good |
| High quality | 60 000 | ~45 min | Excellent |

---

## App Configuration

Open **Settings** tab in the app to configure:

- **Server URL** — Your server's IP or domain (e.g. `http://192.168.1.100:8000`)
- **Capture FPS** — Frames per second (1–10). 5 FPS is ideal for walking speed.
- **LiDAR** — Enable depth-seeded point cloud initialization (faster training, Pro iPhones only)
- **Capture quality** — Image resolution for frames
- **Depth visualization** — Overlay depth map on camera feed during capture

---

## Capture Tips

| Scenario | Recommendation |
|---|---|
| Room scan | Walk slowly along walls, capture all angles |
| Object scan | Circle the object 2–3 times at different heights |
| Speed | ~0.3 m/s (slow walking) |
| Lighting | Bright, diffuse lighting — avoid hard shadows |
| Textureless surfaces | Add temporary texture (paper, fabric) — flat walls are hard |
| Minimum frames | 30–50 frames for good results |
| Ideal frames | 100–200 frames for large rooms |

---

## Standalone Web Viewer

The `viewer/` directory contains a self-contained WebGL 2 Gaussian Splat renderer that works in any modern browser (Chrome, Safari, Firefox).

**Open locally:**
```bash
python3 -m http.server 3000 --directory viewer
# Open: http://localhost:3000
```

**Load a remote .ply:**
```
http://localhost:3000?file=http://your-server:8000/api/jobs/JOB_ID/result
```

**Controls:**
| Gesture | Action |
|---|---|
| Drag / single-finger | Orbit |
| Pinch | Zoom |
| Two-finger drag | Pan |
| Shift + drag (desktop) | Pan |
| Scroll (desktop) | Zoom |

---

## Architecture Deep Dive

### Capture pipeline

The iOS app implements the same data format as [SplatCam](https://apps.apple.com/us/app/splatcam-lidar-capture/id6759800588), outputting a ZIP containing:

```
capture_YYYYMMDD_HHMMSS.zip
├── transforms.json          Nerfstudio-format camera poses
├── images/
│   ├── frame_00000.jpg
│   ├── frame_00001.jpg
│   └── ...
└── depth/                   (LiDAR devices only)
    ├── frame_00000.png      16-bit depth PNG (millimetres)
    └── ...
```

`transforms.json` format:
```json
{
  "camera_model": "OPENCV",
  "fl_x": 1247.3,
  "fl_y": 1247.3,
  "cx": 960.0,
  "cy": 720.0,
  "w": 1920,
  "h": 1440,
  "frames": [
    {
      "file_path": "images/frame_00000.jpg",
      "transform_matrix": [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
        [0, 0, 1, 0],
        [0, 0, 0, 1]
      ]
    }
  ]
}
```

The transform matrix is the **camera-to-world** matrix in OpenCV / Nerfstudio convention (right-handed, Y down, Z into scene). ARKit's right-handed Y-up coordinate system is converted automatically in `ARCaptureManager.swift`.

### 3D Gaussian Splatting

Each Gaussian primitive stores:
- **Position** (x, y, z) — center in 3D space
- **Scale** (3 values) — axis-aligned extent
- **Rotation** (quaternion) — orientation
- **Opacity** — before sigmoid activation
- **Spherical Harmonics** (DC + higher orders) — view-dependent color

Rendering projects each Gaussian to a 2D ellipse via the EWA splatting formula, sorts back-to-front, and alpha-blends. The result is photorealistic with view-dependent effects (reflections, specular highlights).

### Server pipeline

```
Upload (.mp4/.mov video  OR  .zip ARKit capture)
    │
    ├─ Video? ──▶ FFmpeg extracts ~150 JPEG frames
    │                      │
    └─ ZIP? ──▶ Extract     │
                  │         │
                  ├─ Has transforms.json? ─── Yes ──▶ Nerfstudio data dir
                  │                                          │
                  └─── No ──▶ COLMAP SfM ──────────────────┘
                                                            │
                                                            ▼
                                               ns-train splatfacto
                                               (30 000 iterations)
                                                            │
                                                            ▼
                                               ns-export gaussian-splat
                                                            │
                                                            ▼
                                               result.ply → /data/results/{job_id}/
```

---

## Troubleshooting

**App can't connect to server**
- Confirm server is running: `docker compose ps` in `backend/`
- Check server IP — find it with `ip addr` or `ifconfig`
- Ensure iPhone and server are on the same network
- Check firewall allows port 8000: `sudo ufw allow 8000`

**COLMAP fails**
- Ensure frames have enough texture/detail
- Increase frame count (try 80+ frames)
- Check worker logs: `docker compose logs -f worker`

**Training is very slow**
- Confirm GPU is visible: `docker exec scan3d-worker nvidia-smi`
- Check CUDA version matches PyTorch: `docker compose logs worker | head -50`
- Reduce `NERFSTUDIO_MAX_ITERATIONS` in `.env` for quicker results

**Out of VRAM**
- Reduce scene complexity (fewer frames)
- Lower `NERFSTUDIO_MAX_ITERATIONS`
- Scenes > 200 frames may need 16+ GB VRAM

**Viewer shows blank screen**
- Ensure `.ply` file is a Gaussian Splat format (not a mesh)
- Try downloading the `.ply` and dragging it onto `viewer/index.html`
- Check browser console for WebGL errors (Chrome DevTools)

---

## Contributing

Pull requests welcome. Key areas for contribution:

- [ ] Feed-forward single-image reconstruction (Apple SHARP / TripoSR integration)
- [ ] Real-time on-device preview point cloud during capture
- [ ] Android version (ARCore + Kotlin)
- [ ] Push notifications for job completion (APNs)
- [ ] `.spz` compressed format support in viewer
- [ ] Gaussian model editing (crop, scale, merge)

---

## License

MIT — see `LICENSE`.

## References

1. Kerbl et al., "3D Gaussian Splatting for Real-Time Radiance Field Rendering", SIGGRAPH 2023
2. [graphdeco-inria/gaussian-splatting](https://github.com/graphdeco-inria/gaussian-splatting)
3. [nerfstudio-project/nerfstudio](https://github.com/nerfstudio-project/nerfstudio)
4. [nerfstudio-project/gsplat](https://github.com/nerfstudio-project/gsplat)
5. [SplatCam iOS App](https://apps.apple.com/us/app/splatcam-lidar-capture/id6759800588) — reference for ARKit LiDAR capture format
