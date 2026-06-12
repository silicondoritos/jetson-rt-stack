// =============================================================================
// preprocess.cu   CUDA letterbox + int8 quantize kernel (see preprocess.cuh)
// =============================================================================
#include "preprocess.cuh"

// One thread per destination content pixel (lbW x lbH). Bilinear-free nearest
// sample is enough at these scale ratios and keeps it branch-light; the box
// detector is robust to it and we save a full bilinear gather. RGB order, and
// quantize = pixel - 128 (model scale 1/255, zero_point -128).
__global__ void letterbox_quantize_kernel(int8_t* dst, const uchar4* src,
                                          int srcW, int srcH, size_t srcPitch,
                                          int tW, int tC, int padT, int padL,
                                          int lbW, int lbH, int lbX, int lbY) {
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= lbW || y >= lbH) return;

    // map content pixel -> source pixel (nearest)
    int sx = (int)((x + 0.5f) * srcW / lbW);
    int sy = (int)((y + 0.5f) * srcH / lbH);
    if (sx >= srcW) sx = srcW - 1;
    if (sy >= srcH) sy = srcH - 1;
    const uchar4* row = (const uchar4*)((const char*)src + (size_t)sy * srcPitch);
    uchar4 p = row[sx];  // BGRA

    // destination NHWC offset inside the slot: tensor row (padT+lbY+y), col (padL+lbX+x)
    int8_t* d = dst + ((size_t)(padT + lbY + y) * tW + (padL + lbX + x)) * tC;
    d[0] = (int8_t)((int)p.z - 128);  // R (src is BGRA -> .z is R)
    d[1] = (int8_t)((int)p.y - 128);  // G
    d[2] = (int8_t)((int)p.x - 128);  // B
    // channel 3..tC-1 left at the preset pad value (zero_point)
}

void launch_letterbox_quantize(int8_t* dst, const uchar4* srcBGRA, int srcW,
                               int srcH, size_t srcPitch, int tW, int tC, int padT,
                               int padL, int lbW, int lbH, int lbX, int lbY,
                               cudaStream_t stream) {
    dim3 block(16, 16);
    dim3 grid((lbW + block.x - 1) / block.x, (lbH + block.y - 1) / block.y);
    letterbox_quantize_kernel<<<grid, block, 0, stream>>>(
        dst, srcBGRA, srcW, srcH, srcPitch, tW, tC, padT, padL, lbW, lbH, lbX, lbY);
}
