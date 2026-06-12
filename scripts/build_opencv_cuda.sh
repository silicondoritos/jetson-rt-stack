#!/bin/bash
# =============================================================================
# scripts/build_opencv_cuda.sh   build OpenCV with CUDA + cuDNN + GStreamer
# =============================================================================
# Stock `apt python3-opencv` ships WITHOUT CUDA. Every cv2.cuda.* call fails;
# cv2.dnn DNN_TARGET_CUDA silently runs on CPU. For RT vision workloads, that's a
# catastrophic 10-30x slowdown. This script builds OpenCV from source against
# the L4T CUDA stack with the right flags, then installs to /usr/local.
#
# Output: /usr/local/include/opencv4/, /usr/local/lib/libopencv*.so.*,
#         python bindings into /opt/av-env (our venv).
#
# Result is also packaged as a .deb so re-flashing N units doesn't rebuild
# OpenCV N times   the second device through pulls the cached .deb.
#
# Cache: /opt/opencv-cache/opencv-cuda_4.<x>_arm64.deb
#
# Run from jetson_first_boot.sh OR manually. Idempotent: skip if
# /usr/local/lib/libopencv_core.so already exists with CUDA support.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh" 2>/dev/null || true
. "$HERE/lib/log.sh"    2>/dev/null || { echo "[!] missing lib/log.sh" >&2; exit 1; }
. "$HERE/lib/verify.sh" 2>/dev/null || { echo "[!] missing lib/verify.sh" >&2; exit 1; }
. "$HERE/lib/checks.sh" 2>/dev/null || { echo "[!] missing lib/checks.sh" >&2; exit 1; }

PHASE=opencv_cuda
OPENCV_VERSION="${OPENCV_VERSION:-4.10.0}"
OPENCV_CONTRIB_VERSION="$OPENCV_VERSION"
CUDA_ARCH_BIN="${CUDA_ARCH_BIN:-8.7}"   # Orin = sm_87
JOBS="${JOBS:-$(nproc)}"
WORK_DIR="${WORK_DIR:-/var/tmp/opencv-build}"
CACHE_DIR="${CACHE_DIR:-/opt/opencv-cache}"
DEB_NAME="opencv-cuda_${OPENCV_VERSION}_arm64.deb"

if [ "$EUID" -ne 0 ]; then log::fail "must run as root"; fi

log::section "Build OpenCV ${OPENCV_VERSION} with CUDA $CUDA_ARCH_BIN"

# --- Step 1: shortcut   install from cache if present ---------------------
pre_cache()  { return 0; }
exec_cache() {
    if [ -f "$CACHE_DIR/$DEB_NAME" ]; then
        log::ok "Cached deb found   installing"
        dpkg -i "$CACHE_DIR/$DEB_NAME" || apt-get -f install -y
        return 0
    fi
    log::info "No cached deb; will build from source"
    return 1   # signal "not installed yet"
}
post_cache() {
    # Pass if cv2 imports OK with CUDA support; fail otherwise → drives
    # the build path.
    if /opt/av-env/bin/python -c "import cv2; assert cv2.cuda.getCudaEnabledDeviceCount() > 0" \
       2>/dev/null; then
        return 0
    fi
    return 1
}
if STRICT=0 step::run "Try cached OpenCV-CUDA deb" pre_cache exec_cache post_cache; then
    log::ok "OpenCV-CUDA installed from cache. Done."
    exit 0
fi

# --- Step 2: build dependencies -------------------------------------------
pre_deps()  { check::command_exists apt-get; }
exec_deps() {
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        build-essential cmake git pkg-config \
        libgtk-3-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        libavcodec-dev libavformat-dev libswscale-dev \
        libv4l-dev libxvidcore-dev libx264-dev \
        libjpeg-dev libpng-dev libtiff-dev \
        libtbb2 libtbb-dev libdc1394-dev \
        libopenblas-dev libatlas-base-dev liblapack-dev \
        libprotobuf-dev protobuf-compiler \
        python3-dev python3-numpy \
        nvidia-cuda-dev libcudnn9-dev-cuda-12
    # NOT nvidia-cuda-toolkit: that is Ubuntu universe's CUDA 11.5, which
    # conflicts with JetPack's nvidia-cuda-dev 6.x and breaks the whole apt
    # transaction (observed live 2026-06-10). On Jetson the toolkit comes
    # from JetPack (cuda-toolkit-12-6) and lives at /usr/local/cuda.
}
post_deps() {
    check::command_exists cmake
    command -v nvcc >/dev/null 2>&1 || export PATH="/usr/local/cuda/bin:$PATH"
    check::command_exists nvcc || log::warn "nvcc missing   CUDA build will fail (install nvidia-jetpack)"
    check::package_installed libcudnn9-dev-cuda-12 || log::warn "libcudnn9-dev-cuda-12 missing   DNN_CUDA disabled"
    return 0
}
step::run "Install OpenCV build deps" pre_deps exec_deps post_deps

# --- Step 3: fetch sources ------------------------------------------------
pre_src()  { mkdir -p "$WORK_DIR"; cd "$WORK_DIR"; }
exec_src() {
    cd "$WORK_DIR"
    if [ ! -d opencv ]; then
        git clone --depth 1 --branch "$OPENCV_VERSION" https://github.com/opencv/opencv.git
    fi
    if [ ! -d opencv_contrib ]; then
        git clone --depth 1 --branch "$OPENCV_CONTRIB_VERSION" https://github.com/opencv/opencv_contrib.git
    fi
}
post_src() {
    check::dir_nonempty "$WORK_DIR/opencv"
    check::dir_nonempty "$WORK_DIR/opencv_contrib"
}
step::run "Fetch OpenCV + opencv_contrib sources" pre_src exec_src post_src

# --- Step 4: configure + build -------------------------------------------
pre_build()  {
    check::dir_exists "$WORK_DIR/opencv"
    # The bindings compile against the venv's numpy HEADERS and only run on
    # the same major version. The venv must hold the Voyager-pinned numpy<2
    # at configure time, or cv2 imports die with "numpy.core.multiarray
    # failed to import" once the pin is restored (observed live 2026-06-10:
    # pyzed's unbounded dep had bumped the venv to numpy 2.2.6).
    /opt/av-env/bin/python -c 'import numpy; assert int(numpy.__version__.split(".")[0]) < 2, numpy.__version__' \
        || { log::fail "venv numpy is >=2   run: /opt/av-env/bin/pip install \"numpy<2.0.0\" and retry"; return 1; }
}
exec_build() {
    cd "$WORK_DIR/opencv"
    rm -rf build && mkdir build && cd build
    cmake \
        -D CMAKE_BUILD_TYPE=RELEASE \
        -D CMAKE_INSTALL_PREFIX=/usr/local \
        -D OPENCV_EXTRA_MODULES_PATH=../../opencv_contrib/modules \
        -D WITH_CUDA=ON \
        -D WITH_CUDNN=ON \
        -D OPENCV_DNN_CUDA=ON \
        -D ENABLE_FAST_MATH=ON \
        -D CUDA_FAST_MATH=ON \
        -D WITH_CUBLAS=ON \
        -D CUDA_ARCH_BIN="$CUDA_ARCH_BIN" \
        -D CUDA_ARCH_PTX="" \
        -D WITH_GSTREAMER=ON \
        -D WITH_LIBV4L=ON \
        -D WITH_NVCUVID=ON \
        -D WITH_FFMPEG=ON \
        -D WITH_OPENGL=ON \
        -D WITH_TBB=ON \
        -D BUILD_opencv_python3=ON \
        -D PYTHON3_EXECUTABLE=/opt/av-env/bin/python \
        -D BUILD_EXAMPLES=OFF \
        -D BUILD_TESTS=OFF \
        -D BUILD_PERF_TESTS=OFF \
        -D OPENCV_GENERATE_PKGCONFIG=ON \
        -D OPENCV_ENABLE_NONFREE=ON \
        ..
    make -j"$JOBS"
    make install
    ldconfig
}
post_build() {
    check::file_exists /usr/local/lib/libopencv_core.so
    /opt/av-env/bin/python -c "import cv2; print('OpenCV', cv2.__version__, 'CUDA devs', cv2.cuda.getCudaEnabledDeviceCount())"
    /opt/av-env/bin/python -c "import cv2; assert cv2.cuda.getCudaEnabledDeviceCount() > 0, 'no CUDA devices'"
}
step::run "Compile + install OpenCV-CUDA" pre_build exec_build post_build

# --- Step 5: package as .deb for the cache --------------------------------
pre_pkg()  { check::command_exists checkinstall || apt-get install -y checkinstall; }
exec_pkg() {
    mkdir -p "$CACHE_DIR"
    cd "$WORK_DIR/opencv/build"
    checkinstall --pkgname=opencv-cuda --pkgversion="$OPENCV_VERSION" \
                 --requires='libcudnn9-cuda-12,libgstreamer1.0-0' \
                 --pakdir="$CACHE_DIR" \
                 --backup=no --default --nodoc -y \
                 make install || true
    # Fallback: tar the install if checkinstall isn't perfect on this distro.
    if ! ls "$CACHE_DIR"/*.deb >/dev/null 2>&1; then
        log::warn "checkinstall didn't produce a .deb   falling back to tar"
        tar czf "$CACHE_DIR/opencv-cuda_${OPENCV_VERSION}_arm64.tar.gz" -C / \
            usr/local/lib/libopencv* usr/local/include/opencv4
    fi
}
post_pkg() {
    ls "$CACHE_DIR"/opencv-cuda_*.deb >/dev/null 2>&1 \
        || ls "$CACHE_DIR"/opencv-cuda_*.tar.gz >/dev/null 2>&1
}
STRICT=0 step::run "Cache as deb/tar" pre_pkg exec_pkg post_pkg

log::section "OpenCV-CUDA Install Complete"
/opt/av-env/bin/python -c "import cv2; print('OpenCV', cv2.__version__); print('CUDA devices:', cv2.cuda.getCudaEnabledDeviceCount())"
step::summary
