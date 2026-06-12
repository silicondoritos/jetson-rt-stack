// =============================================================================
// examples/zedx_metis_cpp/zedx_metis_infer.cpp   live ZED X -> Metis, pure C++
// =============================================================================
// C++ counterpart of scripts/demo_zedx_metis.py, but without the Voyager app
// framework: ZED SDK grabs HD1200 frames, this file does letterbox + int8
// quantize, runs the 4-core yolov5s artifact via libaxruntime, and decodes
// the raw heads (sigmoid baked into the model) + NMS on the host.
//
// The deployed artifact is batch-4 (one slot per AIPU core), so 4 camera
// frames are packed per inference call; a capture thread overlaps grab +
// preprocess with NPU runs (double-buffered).
//
// Prerequisites (same as the python demo):
//   - model deployed once: cd ~/voyager-sdk && ./inference.py yolov5s-v7-coco \
//       media/h264/traffic1_1080p.mp4
//   - user in the zed group (else: sg zed -c '...')
//
// Build: cmake -B build && cmake --build build         (from this dir)
// Run:   ./build/zedx_metis_infer [--mode HD1200|HD1080|SVGA] [--fps N]
//                                 [--seconds N] [--headless]
//        --model yolov5s-v7-coco|yolov8s-coco   (default yolov5s; both decode
//                paths host-side: v5 anchors, v8 anchor-free DFL)
//        --image <jpg|png|mp4>  decode smoke test, no camera (prints dets)
// ZED X modes: HD1200 1920x1200 @15/30/60, HD1080 1920x1080 @15/30,
//              SVGA 960x600 @15/30/60/120.
//
// Measured end-to-end baselines (2026-06-11, reference device, headless):
//   yolov5s: HD1200@30 30.0 / HD1200@60 56.4 / SVGA@120 74.7 FPS
//   yolov8s: HD1200@60 57.4 / SVGA@120 95.7 FPS
//   with display: yolov5s 35.1, yolov8s 46.9 FPS (HD1200@60, 4x imshow)
// GPU stays ~25% (ZED rectification + compositor only   NPU does detection).
// (python demo_zedx_metis.py: 37.3 / 53.3 FPS with display)
// =============================================================================
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <axruntime/axruntime.h>
#include <axruntime/axruntime.hpp>
#include <opencv2/highgui.hpp>
#include <opencv2/imgproc.hpp>
#include <sl/Camera.hpp>

#include "yolo_decode.hpp"  // shared v5/v8 decode (yolo::Decoder, RawDet, nms...)

namespace {

using yolo::kClasses;
using yolo::kInputSize;
constexpr char kDefaultModel[] = "yolov5s-v7-coco";
constexpr char kBuildRoot[] = "/home/j/voyager-sdk/build/";
constexpr char kCocoNames[] = "/home/j/voyager-sdk/ax_datasets/labels/coco.names";

constexpr float kConfThresh = 0.25f;     // pipeline defaults from the YAML
constexpr float kIouThresh = 0.45f;
constexpr int kMaxBoxes = 300;

// Voyager deploys per core-count subdir (4/, 2/, 1/). A large model may fall
// back to fewer cores, so probe most-cores-first and use whatever exists.
std::string resolve_model_json(const std::string& net) {
    std::string base = std::string(kBuildRoot) + net + "/" + net + "/";
    for (int cores : {4, 2, 1}) {
        std::string p = base + std::to_string(cores) + "/model.json";
        if (std::ifstream(p).good()) return p;
    }
    return base + "4/model.json";  // nonexistent -> triggers clear load error
}

struct Mode { const char* name; sl::RESOLUTION res; int w, h; };
constexpr Mode kModes[] = {
    {"HD1200", sl::RESOLUTION::HD1200, 1920, 1200},
    {"HD1080", sl::RESOLUTION::HD1080, 1920, 1080},
    {"SVGA", sl::RESOLUTION::SVGA, 960, 600},
};

}  // namespace

int main(int argc, char** argv) {
    const Mode* mode = &kModes[0];
    int fps = 60, seconds = 0;   // 0 = run until Esc; --seconds N caps it
    bool headless = false;
    std::string image_path, network = kDefaultModel;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--mode" && i + 1 < argc) {
            std::string m = argv[++i];
            mode = nullptr;
            for (const Mode& c : kModes) if (m == c.name) mode = &c;
            if (!mode) { std::cerr << "unknown mode " << m << "\n"; return 1; }
        } else if (a == "--fps" && i + 1 < argc) fps = std::stoi(argv[++i]);
        else if (a == "--seconds" && i + 1 < argc) seconds = std::stoi(argv[++i]);
        else if (a == "--headless") headless = true;
        else if (a == "--image" && i + 1 < argc) image_path = argv[++i];
        else if (a == "--model" && i + 1 < argc) network = argv[++i];
        else { std::cerr << "usage: see header\n"; return 1; }
    }
    const std::string model_json = resolve_model_json(network);

    Mode image_mode;
    cv::Mat still;
    if (!image_path.empty()) {
        cv::VideoCapture cap(image_path);
        cv::Mat bgr;
        if (!cap.read(bgr)) { std::cerr << "cannot read " << image_path << "\n"; return 1; }
        cv::cvtColor(bgr, still, cv::COLOR_BGR2BGRA);
        image_mode = {"image", sl::RESOLUTION::AUTO, still.cols, still.rows};
        mode = &image_mode;
        headless = true;
        seconds = 0;  // single batch, then exit
    }

    // --- camera ---------------------------------------------------------
    sl::Camera cam;
    if (image_path.empty()) {
        sl::InitParameters init;
        init.camera_resolution = mode->res;
        init.camera_fps = fps;
        init.depth_mode = sl::DEPTH_MODE::NONE;  // detector only; depth costs FPS
        if (sl::ERROR_CODE e = cam.open(init); e != sl::ERROR_CODE::SUCCESS) {
            std::cerr << "ZED X open failed: " << sl::toString(e)
                      << "   run install_zedx_daemons.sh?\n";
            return 1;
        }
        std::cout << "ZED X open: S/N " << cam.getCameraInformation().serial_number
                  << " " << mode->name << "@" << fps << "\n";
    }

    // --- model ----------------------------------------------------------
    auto ctx = axr::to_ptr(axr_create_context());
    auto err = [&] { return axr_last_error_string(AXR_OBJECT(ctx.get())); };
    axrModel* model = axr_load_model(ctx.get(), model_json.c_str());
    if (!model) {
        std::cerr << "load_model " << model_json << ": " << err()
                  << "\n(deploy it once: cd ~/voyager-sdk && ./deploy.py " << network
                  << " --aipu-cores 4)\n";
        return 1;
    }

    axrTensorInfo in_info = axr_get_model_input(model, 0);
    const int batch = in_info.dims[0], tH = in_info.dims[1], tW = in_info.dims[2],
              tC = in_info.dims[3];
    const int padT = in_info.padding[1][0], padL = in_info.padding[2][0];
    const size_t in_frame = (size_t)tH * tW * tC;

    axrConnection* conn = axr_device_connect(ctx.get(), nullptr, batch, nullptr);
    if (!conn) { std::cerr << "connect: " << err() << "\n"; return 1; }
    std::string props = "input_dmabuf=0;double_buffer=1;num_sub_devices=" +
                        std::to_string(batch) + ";aipu_cores=" + std::to_string(batch);
    axrModelInstance* inst = axr_load_model_instance(
        conn, model, axr_create_properties(ctx.get(), props.c_str()));
    if (!inst) { std::cerr << "instance: " << err() << "\n"; return 1; }

    const size_t n_out = axr_num_model_outputs(model);
    std::vector<axrTensorInfo> out_info(n_out);
    std::vector<std::vector<int8_t>> out_buf(n_out);
    std::vector<axrArgument> out_args(n_out);
    for (size_t i = 0; i < n_out; ++i) {
        out_info[i] = axr_get_model_output(model, i);
        out_buf[i].resize(axr_tensor_size(&out_info[i]));
        out_args[i] = {out_buf[i].data(), 0, 0, 0};
    }
    // Shared host decoder (auto-detects v5 anchor vs v8 anchor-free DFL)   also
    // the single source of the letterbox geometry used to preprocess.
    yolo::Decoder dec(out_info, kConfThresh, kIouThresh, kMaxBoxes, mode->w, mode->h);
    std::cout << "model: " << network << " batch=" << batch << " input " << tH
              << "x" << tW << "x" << tC << ", " << n_out << " outputs ("
              << (dec.is_v8() ? "yolov8" : "yolov5") << " decode)\n";

    // --- letterbox geometry (camera -> 640x640, gray=114) -----------------
    const float scale = dec.scale();
    const int lbW = dec.lbW(), lbH = dec.lbH(), lbX = dec.lbX(), lbY = dec.lbY();

    // Two batch input buffers, pre-filled: tensor pad = zero_point (-128),
    // letterbox content region = quantized gray (114 - 128). Quantize is
    // u8 - 128 because scale = 1/255, zp = -128.
    std::vector<int8_t> in_buf[2];
    for (auto& b : in_buf) {
        b.assign(axr_tensor_size(&in_info), (int8_t)in_info.zero_point);
        for (int s = 0; s < batch; ++s)
            for (int y = 0; y < kInputSize; ++y)
                std::memset(b.data() + s * in_frame + ((padT + y) * tW + padL) * tC,
                            114 - 128, (size_t)kInputSize * tC);
    }

    // --- capture thread: grab + letterbox + quantize into in_buf[fill] ----
    std::mutex mx;
    std::condition_variable cv_full, cv_free;
    std::vector<int> readyq;  // buffer indices ready for inference, FIFO
    bool busy[2] = {false, false};
    std::atomic<bool> stop{false};
    cv::Mat bgra_batch[2][8];  // per-slot display copies (max batch 8)
    if (batch > 8) { std::cerr << "batch > 8 unsupported\n"; return 1; }

    std::thread capture([&] {
        sl::Mat img;
        cv::Mat small, rgb;
        int fill = 0;
        while (!stop) {
            {
                std::unique_lock<std::mutex> lk(mx);
                cv_free.wait(lk, [&] { return !busy[fill] || stop; });
                if (stop) return;
            }
            for (int s = 0; s < batch && !stop;) {
                cv::Mat frame;
                if (!still.empty()) {
                    frame = still;
                } else {
                    if (cam.grab() != sl::ERROR_CODE::SUCCESS) continue;
                    cam.retrieveImage(img, sl::VIEW::LEFT);
                    frame = cv::Mat((int)img.getHeight(), (int)img.getWidth(), CV_8UC4,
                                    img.getPtr<sl::uchar1>(), img.getStepBytes());
                }
                if (!headless) frame.copyTo(bgra_batch[fill][s]);
                cv::resize(frame, small, {lbW, lbH}, 0, 0, cv::INTER_LINEAR);
                cv::cvtColor(small, rgb, cv::COLOR_BGRA2RGB);
                int8_t* dst = in_buf[fill].data() + s * in_frame +
                              ((padT + lbY) * tW + padL + lbX) * tC;
                for (int y = 0; y < lbH; ++y) {
                    const uint8_t* sp = rgb.ptr(y);
                    int8_t* dp = dst + (size_t)y * tW * tC;
                    for (int x = 0; x < lbW; ++x, sp += 3, dp += tC) {
                        dp[0] = sp[0] - 128; dp[1] = sp[1] - 128; dp[2] = sp[2] - 128;
                    }
                }
                ++s;
            }
            {
                std::lock_guard<std::mutex> lk(mx);
                busy[fill] = true;
                readyq.push_back(fill);
            }
            cv_full.notify_one();
            fill ^= 1;
        }
    });

    // --- decode (shared header) -------------------------------------------
    auto labels = yolo::load_labels(kCocoNames);
    auto decode_slot = [&](int slot, std::vector<yolo::RawDet>& dets) {
        dec.decode(slot, out_buf, dets);
    };

    // --- inference loop ----------------------------------------------------
    if (!headless) {
        cv::namedWindow("ZED X -> Metis (C++)", cv::WINDOW_NORMAL);
        cv::resizeWindow("ZED X -> Metis (C++)", 800, 600);
    }
    auto t0 = std::chrono::steady_clock::now();
    long frames = 0;
    std::vector<yolo::RawDet> dets;
    axrArgument in_arg{nullptr, 0, 0, 0};
    bool once = !image_path.empty();
    while (once || seconds <= 0 ||
           std::chrono::steady_clock::now() - t0 < std::chrono::seconds(seconds)) {
        once = false;
        int cur;
        {
            std::unique_lock<std::mutex> lk(mx);
            cv_full.wait(lk, [&] { return !readyq.empty(); });
            cur = readyq.front();
            readyq.erase(readyq.begin());
        }
        in_arg.ptr = in_buf[cur].data();
        if (axr_run_model_instance(inst, &in_arg, 1, out_args.data(), n_out)
            != AXR_SUCCESS) {
            std::cerr << "run: " << err() << "\n";
            break;
        }
        frames += batch;
        for (int s = 0; s < batch && !headless; ++s) {
            decode_slot(s, dets);
            cv::Mat& vis = bgra_batch[cur][s];
            for (const yolo::RawDet& d : dets) {
                cv::rectangle(vis, {(int)d.x0, (int)d.y0}, {(int)d.x1, (int)d.y1},
                              {0, 255, 0, 255}, 2);
                cv::putText(vis, labels[d.cls], {(int)d.x0, (int)d.y0 - 4},
                            cv::FONT_HERSHEY_SIMPLEX, 0.6, {0, 255, 0, 255}, 2);
            }
            cv::imshow("ZED X -> Metis (C++)", vis);
            if (cv::waitKey(1) == 27) stop = true;
        }
        if (headless) decode_slot(batch - 1, dets);  // count postproc honestly
        if (!image_path.empty()) {
            for (const yolo::RawDet& d : dets)
                std::cout << labels[d.cls] << " " << d.score << " [" << (int)d.x0
                          << "," << (int)d.y0 << " " << (int)d.x1 << "," << (int)d.y1
                          << "]\n";
            break;  // image = single batch, then exit (don't loop forever)
        }
        {
            std::lock_guard<std::mutex> lk(mx);
            busy[cur] = false;
        }
        cv_free.notify_one();
        if (stop) break;
        if (frames % 240 == 0) {
            double s = std::chrono::duration<double>(
                           std::chrono::steady_clock::now() - t0).count();
            std::cout << frames << " frames, " << frames / s << " FPS, last "
                      << dets.size() << " dets\n";
        }
    }
    double secs =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::cout << frames << " frames in " << secs << "s (end-to-end "
              << frames / secs << " FPS)\n";
    stop = true;
    cv_free.notify_all();
    capture.join();
    if (image_path.empty()) cam.close();
    return 0;
}
