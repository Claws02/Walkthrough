#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   ScanCapture 3D  —  Setup Script        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

MODE="${1:-}"

# ─── iOS App Setup ────────────────────────────────────────────────────────────
setup_ios() {
  info "Setting up iOS project..."

  if ! command -v xcodegen &>/dev/null; then
    if command -v brew &>/dev/null; then
      info "Installing XcodeGen via Homebrew..."
      brew install xcodegen
    else
      error "XcodeGen not found. Install it: brew install xcodegen\n       or: https://github.com/yonaskolb/XcodeGen"
    fi
  fi

  if [[ ! "$(uname)" == "Darwin" ]]; then
    error "iOS project setup requires macOS with Xcode installed."
  fi

  if ! command -v xcodebuild &>/dev/null; then
    error "Xcode not found. Install Xcode from the Mac App Store."
  fi

  info "Generating Xcode project from project.yml..."
  cd ios && xcodegen generate && cd ..

  success "Xcode project generated at ios/ScanCapture.xcodeproj"
  echo ""
  echo -e "  Next steps:"
  echo -e "  1. ${YELLOW}open ios/ScanCapture.xcodeproj${NC}"
  echo -e "  2. Select your development team in Signing & Capabilities"
  echo -e "  3. Connect your iPhone and press Run (⌘R)"
  echo ""
}

# ─── Backend Setup ────────────────────────────────────────────────────────────
setup_backend() {
  info "Setting up backend..."

  if ! command -v docker &>/dev/null; then
    error "Docker not found. Install Docker Desktop: https://www.docker.com/get-started"
  fi

  if ! command -v docker compose &>/dev/null && ! command -v docker-compose &>/dev/null; then
    error "Docker Compose not found. Ensure Docker Compose v2 is installed."
  fi

  cd backend

  if [[ ! -f .env ]]; then
    cp .env.example .env
    success "Created backend/.env from template"
    warn "Review backend/.env and adjust settings (especially NERFSTUDIO_MAX_ITERATIONS)"
  else
    info "backend/.env already exists, skipping."
  fi

  # Check for GPU
  if command -v nvidia-smi &>/dev/null; then
    success "NVIDIA GPU detected."
    if ! docker info 2>/dev/null | grep -q "nvidia"; then
      warn "NVIDIA Docker runtime not found. GPU acceleration may not work."
      warn "Install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
    fi
  else
    warn "No NVIDIA GPU detected. The worker will use CPU (very slow training)."
    warn "For best results, use a machine with an NVIDIA RTX 3090/4090 or better."
    # Remove GPU requirement from docker-compose for CPU-only
    sed -i.bak '/reservations:/,/capabilities: \[gpu\]/d' docker-compose.yml 2>/dev/null || true
  fi

  info "Building Docker images (this may take 20-40 minutes on first run)..."
  docker compose build

  success "Backend Docker images built successfully."
  cd ..

  echo ""
  echo -e "  Start the backend:"
  echo -e "  ${YELLOW}cd backend && docker compose up -d${NC}"
  echo ""
  echo -e "  View logs:"
  echo -e "  ${YELLOW}docker compose logs -f${NC}"
  echo ""
  echo -e "  Web UI will be available at: ${YELLOW}http://localhost${NC}"
  echo -e "  API docs:                    ${YELLOW}http://localhost/api/docs${NC}"
  echo ""
}

# ─── Viewer Setup ─────────────────────────────────────────────────────────────
setup_viewer() {
  info "Web viewer is standalone — no build step required."
  echo ""
  echo -e "  Open in browser: ${YELLOW}viewer/index.html${NC}"
  echo -e "  Or serve with:   ${YELLOW}python3 -m http.server 3000 --directory viewer${NC}"
  echo ""
  echo -e "  Load a .ply file via URL: ${YELLOW}http://localhost:3000?file=http://your-server/jobs/ID/result${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
case "$MODE" in
  ios)     setup_ios     ;;
  backend) setup_backend ;;
  viewer)  setup_viewer  ;;
  all)
    setup_backend
    if [[ "$(uname)" == "Darwin" ]]; then setup_ios; fi
    setup_viewer
    ;;
  *)
    echo "Usage: $0 [ios|backend|viewer|all]"
    echo ""
    echo "  ios      — Generate Xcode project (macOS only)"
    echo "  backend  — Build Docker images for the processing server"
    echo "  viewer   — Info about the standalone web viewer"
    echo "  all      — Run all setup steps"
    echo ""
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "Detected macOS. Running full setup..."
      setup_backend
      setup_ios
      setup_viewer
    else
      echo "Detected Linux/other. Running backend + viewer setup..."
      setup_backend
      setup_viewer
    fi
    ;;
esac

echo -e "${GREEN}Setup complete.${NC}"
