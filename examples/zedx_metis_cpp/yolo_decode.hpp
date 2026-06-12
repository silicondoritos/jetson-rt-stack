// =============================================================================
// yolo_decode.hpp   shared YOLOv5/v8 host decode for the ZED X + Metis samples
// =============================================================================
// Factored out of zedx_metis_infer.cpp / zedx_metis_fusion.cpp so the decode
// math lives in exactly one place (the adversarial review found the same OOB
// bug had to be fixed twice when it was duplicated). Both v5 (anchor) and v8
// (anchor-free DFL) heads are auto-detected from the runtime tensor count.
// =============================================================================
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

#include <axruntime/axruntime.h>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

namespace yolo {

constexpr int kInputSize = 640;
constexpr int kClasses = 80;

struct RawDet {
    float x0, y0, x1, y1, score;
    int cls;
};

struct Level { int stride; float anchors[3][2]; };
inline constexpr Level kLevels[] = {
    {8, {{1.25f, 1.625f}, {2.0f, 3.75f}, {4.125f, 2.875f}}},
    {16, {{1.875f, 3.8125f}, {3.875f, 2.8125f}, {3.6875f, 7.4375f}}},
    {32, {{3.625f, 2.8125f}, {4.875f, 6.1875f}, {11.65625f, 10.1875f}}},
};

inline float iou(const RawDet& a, const RawDet& b) {
    float ix = std::max(0.f, std::min(a.x1, b.x1) - std::max(a.x0, b.x0));
    float iy = std::max(0.f, std::min(a.y1, b.y1) - std::max(a.y0, b.y0));
    float inter = ix * iy;
    float ua = (a.x1 - a.x0) * (a.y1 - a.y0) + (b.x1 - b.x0) * (b.y1 - b.y0) - inter;
    return ua > 0 ? inter / ua : 0.f;
}

inline void nms(std::vector<RawDet>& dets, float iou_thresh, int max_boxes) {
    std::sort(dets.begin(), dets.end(),
              [](const RawDet& a, const RawDet& b) { return a.score > b.score; });
    std::vector<RawDet> kept;
    kept.reserve(max_boxes);
    for (const RawDet& d : dets) {
        bool keep = true;
        for (const RawDet& k : kept)
            if (k.cls == d.cls && iou(k, d) > iou_thresh) { keep = false; break; }
        if (keep) {
            kept.push_back(d);
            if ((int)kept.size() >= max_boxes) break;
        }
    }
    dets.swap(kept);
}

inline std::vector<std::string> load_labels(const char* path) {
    std::vector<std::string> labels;
    std::ifstream f(path);
    for (std::string line; std::getline(f, line);) labels.push_back(line);
    if ((int)labels.size() < kClasses) labels.resize(kClasses, "?");  // never index OOB
    return labels;
}

// Deterministic per-class palette: golden-angle hue walk, saturated, bright.
inline std::vector<cv::Scalar> make_palette(int n) {
    std::vector<cv::Scalar> p(n);
    cv::Mat hsv(1, 1, CV_8UC3), bgr;
    for (int i = 0; i < n; ++i) {
        hsv.at<cv::Vec3b>(0, 0) = {(uint8_t)((i * 47) % 180), 220, 255};
        cv::cvtColor(hsv, bgr, cv::COLOR_HSV2BGR);
        auto v = bgr.at<cv::Vec3b>(0, 0);
        p[i] = {(double)v[0], (double)v[1], (double)v[2], 255};
    }
    return p;
}

// Stateless decoder: reads model tensor metadata once, then decodes a batch
// slot's raw int8 output buffers into image-space boxes (letterbox-unmapped).
class Decoder {
public:
    // LUTs + letterbox geometry are built once; the int8 output buffers are
    // passed per decode() call so one Decoder serves many pipeline slots.
    Decoder(const std::vector<axrTensorInfo>& out_info, float conf, float iou,
            int max_boxes, int cam_w, int cam_h)
        : out_info_(out_info), conf_(conf), iou_(iou),
          max_boxes_(max_boxes), n_out_(out_info.size()), v8_(out_info.size() == 6) {
        scale_ = (float)kInputSize / std::max(cam_w, cam_h);
        lbW_ = (int)std::round(cam_w * scale_);
        lbH_ = (int)std::round(cam_h * scale_);
        lbX_ = (kInputSize - lbW_) / 2;
        lbY_ = (kInputSize - lbH_) / 2;
        lut_.resize(n_out_); sig_.resize(n_out_); expt_.resize(n_out_);
        for (size_t i = 0; i < n_out_; ++i)
            for (int q = 0; q < 256; ++q) {
                float d = (float)(((int8_t)q - out_info[i].zero_point) * out_info[i].scale);
                lut_[i][q] = d;
                sig_[i][q] = 1.f / (1.f + std::exp(-d));
                expt_[i][q] = std::exp(d);
            }
    }

    bool is_v8() const { return v8_; }
    float scale() const { return scale_; }
    int lbX() const { return lbX_; }
    int lbY() const { return lbY_; }
    int lbW() const { return lbW_; }
    int lbH() const { return lbH_; }

    void decode(int slot, const std::vector<std::vector<int8_t>>& out_buf,
                std::vector<RawDet>& dets) const {
        dets.clear();
        v8_ ? decode_v8(slot, out_buf, dets) : decode_v5(slot, out_buf, dets);
        nms(dets, iou_, max_boxes_);
    }

private:
    int logical_ch(size_t t) const {
        return (int)(out_info_[t].dims[3] - out_info_[t].padding[3][0] -
                     out_info_[t].padding[3][1]);
    }

    void decode_v5(int slot, const std::vector<std::vector<int8_t>>& out_buf,
                   std::vector<RawDet>& dets) const {
        for (size_t t = 0; t < n_out_; ++t) {
            const int g = out_info_[t].dims[1], ch = out_info_[t].dims[3];
            const Level* lv = nullptr;
            for (const Level& l : kLevels) if (kInputSize / l.stride == g) lv = &l;
            if (!lv) continue;
            const int8_t* base = out_buf[t].data() + (size_t)slot * g * g * ch;
            const auto& L = lut_[t];
            for (int y = 0; y < g; ++y)
                for (int x = 0; x < g; ++x) {
                    const int8_t* cell = base + ((size_t)y * g + x) * ch;
                    for (int a = 0; a < 3; ++a) {
                        const int8_t* d = cell + a * 85;
                        float obj = L[(uint8_t)d[4]];
                        if (obj < conf_) continue;
                        int best = 0; int8_t bq = d[5];
                        for (int c = 1; c < kClasses; ++c)
                            if (d[5 + c] > bq) { bq = d[5 + c]; best = c; }
                        float score = obj * L[(uint8_t)bq];
                        if (score < conf_) continue;
                        float cx = (L[(uint8_t)d[0]] * 2 - 0.5f + x) * lv->stride;
                        float cy = (L[(uint8_t)d[1]] * 2 - 0.5f + y) * lv->stride;
                        float w2 = L[(uint8_t)d[2]] * 2, h2 = L[(uint8_t)d[3]] * 2;
                        float w = w2 * w2 * lv->anchors[a][0] * lv->stride;
                        float h = h2 * h2 * lv->anchors[a][1] * lv->stride;
                        dets.push_back({(cx - w / 2 - lbX_) / scale_,
                                        (cy - h / 2 - lbY_) / scale_,
                                        (cx + w / 2 - lbX_) / scale_,
                                        (cy + h / 2 - lbY_) / scale_, score, best});
                    }
                }
        }
    }

    void decode_v8(int slot, const std::vector<std::vector<int8_t>>& out_buf,
                   std::vector<RawDet>& dets) const {
        for (size_t ct = 0; ct < n_out_; ++ct) {
            if (logical_ch(ct) != kClasses) continue;
            const int g = out_info_[ct].dims[1];
            size_t bt = n_out_;
            for (size_t t = 0; t < n_out_; ++t)
                if (t != ct && (int)out_info_[t].dims[1] == g && logical_ch(t) == 64)
                    bt = t;
            if (bt == n_out_) continue;  // no paired DFL box tensor   skip, no OOB
            const int cch = out_info_[ct].dims[3], bch = out_info_[bt].dims[3];
            const int stride = kInputSize / g;
            const int8_t* cbase = out_buf[ct].data() + (size_t)slot * g * g * cch;
            const int8_t* bbase = out_buf[bt].data() + (size_t)slot * g * g * bch;
            const auto& S = sig_[ct];
            const auto& E = expt_[bt];
            const float logit = std::log(conf_ / (1 - conf_));
            const int qgate = (int)std::ceil(logit / out_info_[ct].scale) +
                              out_info_[ct].zero_point;
            for (int y = 0; y < g; ++y)
                for (int x = 0; x < g; ++x) {
                    const int8_t* c = cbase + ((size_t)y * g + x) * cch;
                    int best = 0; int8_t bq = c[0];
                    for (int k = 1; k < kClasses; ++k)
                        if (c[k] > bq) { bq = c[k]; best = k; }
                    if (bq < qgate) continue;
                    const int8_t* b = bbase + ((size_t)y * g + x) * bch;
                    float ltrb[4];
                    for (int side = 0; side < 4; ++side, b += 16) {
                        float sum = 0, acc = 0;
                        for (int j = 0; j < 16; ++j) {
                            float e = E[(uint8_t)b[j]]; sum += e; acc += j * e;
                        }
                        ltrb[side] = acc / sum;
                    }
                    dets.push_back({(((x + 0.5f - ltrb[0]) * stride) - lbX_) / scale_,
                                    (((y + 0.5f - ltrb[1]) * stride) - lbY_) / scale_,
                                    (((x + 0.5f + ltrb[2]) * stride) - lbX_) / scale_,
                                    (((y + 0.5f + ltrb[3]) * stride) - lbY_) / scale_,
                                    S[(uint8_t)bq], best});
                }
        }
    }

    const std::vector<axrTensorInfo>& out_info_;
    float conf_, iou_, scale_;
    int max_boxes_, lbW_, lbH_, lbX_, lbY_;
    size_t n_out_;
    bool v8_;
    std::vector<std::array<float, 256>> lut_, sig_, expt_;
};

}  // namespace yolo
