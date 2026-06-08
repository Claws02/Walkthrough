# ---------------------------------------------------------------------------
# Stage 0 – CUDA + Python base
# ---------------------------------------------------------------------------
FROM nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04

# Avoid interactive prompts during apt installs.
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        # Python 3.11
        software-properties-common \
        python3.11 \
        python3.11-dev \
        python3.11-venv \
        python3-pip \
        # Build tools (required by some Python extensions)
        build-essential \
        cmake \
        ninja-build \
        git \
        curl \
        wget \
        # COLMAP runtime dependencies
        libboost-program-options-dev \
        libboost-filesystem-dev \
        libboost-graph-dev \
        libboost-system-dev \
        libboost-test-dev \
        libeigen3-dev \
        libflann-dev \
        libfreeimage-dev \
        libmetis-dev \
        libgoogle-glog-dev \
        libgflags-dev \
        libsqlite3-dev \
        libglew-dev \
        qtbase5-dev \
        libqt5opengl5-dev \
        libcgal-dev \
        libceres-dev \
        libatlas-base-dev \
        libsuitesparse-dev \
        # Media / image utilities
        ffmpeg \
        libexiv2-dev \
        # Cleanup
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install COLMAP from pre-built binary (Ubuntu 22.04 ships COLMAP 3.x)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends colmap \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Make python3.11 the default python / pip
# ---------------------------------------------------------------------------
RUN update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1 \
    && update-alternatives --install /usr/bin/python  python  /usr/bin/python3.11 1 \
    && python3.11 -m pip install --upgrade pip setuptools wheel

# ---------------------------------------------------------------------------
# PyTorch with CUDA 12.1
# ---------------------------------------------------------------------------
RUN pip install --no-cache-dir \
        torch==2.1.2+cu121 \
        torchvision==0.16.2+cu121 \
        --extra-index-url https://download.pytorch.org/whl/cu121

# ---------------------------------------------------------------------------
# Nerfstudio (installs gsplat, tinycudann and all NeRF deps)
# ---------------------------------------------------------------------------
# Pre-install ninja so that CUDA extensions compile faster.
RUN pip install --no-cache-dir ninja

# Install nerfstudio and its dependencies.
RUN pip install --no-cache-dir nerfstudio>=1.1.0

# ---------------------------------------------------------------------------
# Worker-specific Python requirements
# ---------------------------------------------------------------------------
WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# Application code
# ---------------------------------------------------------------------------
COPY app/ /app/app/

# ---------------------------------------------------------------------------
# Data directories (shared with the API container via a Docker volume)
# ---------------------------------------------------------------------------
RUN mkdir -p /data/uploads /data/results /data/work

# ---------------------------------------------------------------------------
# Non-root user
# ---------------------------------------------------------------------------
RUN useradd --create-home --shell /bin/bash worker \
    && chown -R worker:worker /app /data
USER worker

# ---------------------------------------------------------------------------
# Default command
# ---------------------------------------------------------------------------
# --concurrency=1 is critical: each job consumes an entire GPU and many GBs
# of VRAM; running more than one at a time will cause OOM errors.
CMD ["celery", "-A", "app.celery_app", "worker", \
     "--loglevel=info", "--concurrency=1", "--queues=default"]
