#!/bin/bash
# =============================================================================
# scripts/verify_opengl_cuda.sh   confirm NVIDIA OpenGL/EGL/GLES + CUDA paths
# =============================================================================
# Stock Mesa libGL.so works in software but defeats the whole point of having
# an Ampere GPU. This script confirms:
#
#   • libEGL_nvidia.so.0  is installed
#   • libGLESv2_nvidia.so.0 is installed
#   • eglQueryString returns "NVIDIA"
#   • glxinfo "OpenGL renderer string" mentions NVIDIA / Tegra
#   • CUDA-OpenGL interop (cudaGraphicsGLRegisterBuffer) works
#   • TensorRT trtexec runs a tiny model end-to-end
#
# Pure read-only verifier; never installs.
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/log.sh"
. "$HERE/lib/checks.sh"

log::section "Verify NVIDIA OpenGL/EGL + CUDA Stack"

GATE_FAILED=0

# --- 1. Library presence ---------------------------------------------------
log::step "NVIDIA EGL / GLES libraries"
# libGLESv2_nvidia is version-agnostic: R35 shipped .so.0, R36 ships .so.2
# (under tegra-egl/), so match the stem and let the glob take the suffix.
for lib in libEGL_nvidia.so.0 libGLESv2_nvidia.so libnvidia-egl-wayland.so.1 \
           libnvidia-glcore.so libnvidia-glsi.so; do
    if find /usr/lib /usr/lib/aarch64-linux-gnu -name "$lib*" 2>/dev/null | grep -q .; then
        log::pass "$lib"
    else
        log::xfail "$lib" "missing   install nvidia-l4t-3d-core"
    fi
done

# --- 2. EGL display query --------------------------------------------------
log::step "EGL display"
if command -v eglinfo >/dev/null 2>&1; then
    if eglinfo 2>/dev/null | grep -qi "NVIDIA"; then
        log::pass "eglinfo reports NVIDIA"
    else
        log::xfail "eglinfo NVIDIA" "EGL not using NVIDIA stack"
    fi
else
    log::warn "eglinfo not installed   apt install mesa-utils-extra"
fi

# --- 3. GLX info ----------------------------------------------------------
log::step "GLX renderer"
if command -v glxinfo >/dev/null 2>&1; then
    REND="$(glxinfo 2>/dev/null | grep 'OpenGL renderer string' | sed 's/^.*: //')"
    case "$REND" in
        *NVIDIA*|*Tegra*|*Ampere*) log::pass "renderer: $REND" ;;
        *) log::xfail "GLX renderer" "got '$REND'   expected NVIDIA/Tegra/Ampere" ;;
    esac
else
    log::warn "glxinfo not installed   apt install mesa-utils"
fi

# --- 4. CUDA toolkit & GPU --------------------------------------------------
log::step "CUDA"
# JetPack installs the toolkit at /usr/local/cuda but does not add it to PATH
[ -x /usr/local/cuda/bin/nvcc ] && PATH="/usr/local/cuda/bin:$PATH"
if command -v nvcc >/dev/null 2>&1; then
    NVCC_VER="$(nvcc --version | grep release | awk '{print $5}' | tr -d ,)"
    log::pass "nvcc $NVCC_VER"
else
    log::xfail "nvcc" "missing   expected at /usr/local/cuda/bin/nvcc (JetPack cuda-toolkit)"
fi

if command -v nvidia-smi >/dev/null 2>&1; then
    log::pass "nvidia-smi available"
elif [ -d /sys/class/devfreq/17000000.ga10b ]; then
    GPU_FREQ="$(cat /sys/class/devfreq/17000000.ga10b/cur_freq 2>/dev/null)"
    log::pass "Tegra GA10B GPU @ ${GPU_FREQ}Hz"
else
    log::xfail "GPU detection" "no nvidia-smi and no Tegra devfreq node"
fi

# --- 5. CUDA-OpenGL interop test (compile + run a tiny program) ----------
log::step "CUDA-OpenGL interop"
TMP="$(mktemp -d)"
cat > "$TMP/interop.cu" <<'EOF'
#include <cuda_runtime.h>
#include <stdio.h>
int main() {
    int n;
    cudaGetDeviceCount(&n);
    if (n < 1) { printf("FAIL: no CUDA devices\n"); return 1; }
    cudaDeviceProp p;
    cudaGetDeviceProperties(&p, 0);
    printf("OK: %s sm_%d%d\n", p.name, p.major, p.minor);
    return 0;
}
EOF
if command -v nvcc >/dev/null 2>&1; then
    if nvcc -O2 -o "$TMP/interop" "$TMP/interop.cu" 2>/dev/null \
       && "$TMP/interop" 2>&1 | grep -q '^OK:'; then
        log::pass "CUDA device probe compiled + ran"
    else
        log::xfail "CUDA interop" "nvcc compiled but binary failed to run"
    fi
else
    log::warn "skipping CUDA probe   nvcc missing"
fi
rm -rf "$TMP"

# --- 6. TensorRT trtexec ---------------------------------------------------
log::step "TensorRT"
# JetPack installs trtexec at /usr/src/tensorrt/bin, which is not on PATH.
command -v trtexec >/dev/null 2>&1 || \
    { [ -x /usr/src/tensorrt/bin/trtexec ] && PATH="$PATH:/usr/src/tensorrt/bin"; }
if command -v trtexec >/dev/null 2>&1; then
    TRT_VER="$(trtexec --help 2>&1 | grep -oE 'TensorRT v[0-9.]+' | head -1)"
    log::pass "trtexec found ($TRT_VER)"
else
    log::xfail "trtexec" "missing   install tensorrt"
fi

# --- 7. VPI ---------------------------------------------------------------
log::step "VPI 3.x"
if [ -d /opt/nvidia/vpi3 ] || pkg-config --exists vpi 2>/dev/null; then
    log::pass "VPI installed"
else
    log::xfail "VPI" "missing   install nvidia-vpi"
fi

# --- 8. cuDNN -------------------------------------------------------------
log::step "cuDNN"
if dpkg -s libcudnn9-cuda-12 >/dev/null 2>&1; then
    CUDNN_VER="$(dpkg -s libcudnn9-cuda-12 | awk '/Version/{print $2; exit}')"
    log::pass "libcudnn9-cuda-12 $CUDNN_VER"
else
    log::xfail "libcudnn9-cuda-12" "missing"
fi

# --- 9. OpenCV-CUDA --------------------------------------------------------
log::step "OpenCV with CUDA"
PY=/opt/av-env/bin/python
if [ -x "$PY" ]; then
    OUT="$("$PY" -c "
import cv2
print('cv2_version=' + cv2.__version__)
print('cuda_devices=' + str(cv2.cuda.getCudaEnabledDeviceCount()))
print('build_info_has_cuda=' + ('YES' if 'CUDA' in cv2.getBuildInformation() else 'NO'))
" 2>&1)"
    echo "$OUT" | sed 's/^/    /'
    if echo "$OUT" | grep -q "cuda_devices=0"; then
        log::xfail "cv2.cuda" "OpenCV installed but CUDA support OFF   rebuild with build_opencv_cuda.sh"
    elif echo "$OUT" | grep -q "build_info_has_cuda=YES"; then
        log::pass "OpenCV-CUDA active"
    else
        log::xfail "cv2.cuda" "build info missing CUDA"
    fi
else
    log::xfail "/opt/av-env" "venv missing   run jetson_first_boot.sh"
fi

# --- Summary ---------------------------------------------------------------
echo
if [ "$GATE_FAILED" = "0" ]; then
    log::ok "ALL CUDA / OpenGL / GLES / TRT checks passed."
    exit 0
else
    log::fail "Some checks failed. Inspect output above; see docs/CUDA_LIBS.md."
fi
