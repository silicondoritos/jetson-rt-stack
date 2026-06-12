// =============================================================================
// preprocess.cuh   GPU letterbox + int8 quantize for the Metis input tensor
// =============================================================================
// Host-callable launcher (defined in preprocess.cu). Takes the ZED left image
// already on the GPU (BGRA, pitched) and writes the model's NHWC int8 input
// slot directly   letterboxed, channel-padded, and quantized (u8-128)   on a
// CUDA stream. This replaces the download + scalar CPU quantize loop; the
// result is copied once into a dma-heap buffer the Metis DMAs from (no extra
// staging copy inside the runtime).
// =============================================================================
#pragma once
#include <cstdint>
#include <cuda_runtime.h>

// Fills one batch slot of the int8 NHWC tensor from a BGRA GPU image.
//  dst        : device pointer to the slot origin (tensor base + slot*frame)
//  srcBGRA    : device BGRA8 image (ZED left, MEM::GPU)
//  srcW/srcH  : source dims; srcPitch : source row stride in BYTES
//  tW/tC      : tensor width and channels (NHWC, channel-padded e.g. 4)
//  padT/padL  : tensor letterbox-region top/left pad (tensor coords)
//  lbW/lbH    : letterboxed content size; lbX/lbY : content offset inside 640
//  zp         : zero_point (pad fill is preset; content writes pixel-128 style)
// The whole tensor must be preset to zero_point + gray once on the host; this
// kernel only writes the live content rectangle each frame.
void launch_letterbox_quantize(int8_t* dst, const uchar4* srcBGRA, int srcW,
                               int srcH, size_t srcPitch, int tW, int tC, int padT,
                               int padL, int lbW, int lbH, int lbX, int lbY,
                               cudaStream_t stream);
