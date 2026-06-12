// =============================================================================
// examples/zedx_metis_cpp/zedx_metis_fusion.cpp   ZED X + Metis sensor fusion
// =============================================================================
// Every accelerator on the board, working at once, in a 3-stage pipeline
// (capture ∥ inference ∥ render) so each stage overlaps the others:
//
//   Metis NPU  - yolov5/v8 detection (shared host decode in yolo_decode.hpp)
//   Jetson GPU - ZED rectification + NEURAL_LIGHT depth; a CUDA kernel does the
//                letterbox + int8 quantize straight from the ZED GPU image
//                (preprocess.cu) into a dma-heap buffer the Metis DMAs from
//                (no CPU quantize loop, no staging copy); display frame is
//                GPU-downscaled before download. All GPU work rides the ZED
//                CUDA stream.
//   ZED AI     - skeleton/body tracking (HUMAN_BODY_FAST, BODY_18, FP16)
//   IMU        - SDK-fused world pose + a bottom-left linear-accel 3-vector gizmo
//
// Fusion on the CPU: per detection, depth (median of a DEPTH F32_C1 patch) ->
// distance; deproject + pose -> world-frame XYZ; an IoU tracker assigns stable
// ids and estimates velocity / time-to-collision; ZED bodies are matched to
// "person" boxes so the head keep-out uses real head keypoints (2D) and the
// 3D head position comes from keypoint[NOSE] in meters.
//
// Output: optional annotated MP4 (NVENC via GStreamer, software fallback) and
// optional UDP JSON publish of detections for a downstream planner.
//
// Memory: every device/pinned/dma-heap/host buffer is preallocated in a fixed
// ring of slots; zero per-frame allocation; NaN/finite-guarded sampling.
//
// Build: cmake -B build && cmake --build build      (CUDA + libaxldev)
// Run:   ./build/zedx_metis_fusion [--model NAME] [--mode HD1200|HD1080|SVGA]
//          [--fps N] [--seconds N] [--headless] [--no-bodies]
//          [--conf F] [--iou F] [--depth-max M] [--head-frac F] [--kp-conf F]
//          [--depth-every N]  (depth+skeleton every Nth frame; default 3)
//          [--model-root DIR] [--labels PATH]
//          [--record out.mp4] [--publish HOST:PORT]
//
// Performance: depth (NEURAL_LIGHT, in grab()) and the body net are the only
// heavy iGPU consumers and gate the frame; running them every Nth grab while
// detection (Metis NPU) + display run every frame lifts the live rate from
// ~28 toward the camera/NPU limit, with depth/skeleton at ~rate/N.
// =============================================================================
#include <algorithm>
#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

#include <axruntime/axruntime.h>
#include <axruntime/axruntime.hpp>
#include <cuda_runtime.h>
#include <opencv2/core/cuda.hpp>
#include <opencv2/core/cuda_stream_accessor.hpp>
#include <opencv2/cudawarping.hpp>
#include <opencv2/highgui.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/videoio.hpp>
#include <sl/Camera.hpp>

#include "preprocess.cuh"
#include "yolo_decode.hpp"

// libaxldev dma-heap allocator (optional at runtime; #1 falls back to host).
#if __has_include(<AxeleraDmaBuf.hpp>)
#include <AxeleraDmaBuf.hpp>
#define HAVE_AXDMABUF 1
#else
#define HAVE_AXDMABUF 0
#endif

namespace {
using yolo::kClasses;
using yolo::kInputSize;

constexpr char kDefaultModel[] = "yolov8l-coco";  // largest/most accurate deployed
constexpr int kPersonClass = 0;
constexpr int kBody18 = 18, kMaxBodies = 16;
constexpr int kRing = 4;  // pipeline slots in flight

// BODY_18 bone links (index pairs, mirrors sl::BODY_18_BONES).
constexpr int kBones[][2] = {
    {0, 1}, {1, 2}, {2, 3}, {3, 4}, {1, 5}, {5, 6}, {6, 7}, {2, 8}, {8, 9},
    {9, 10}, {5, 11}, {11, 12}, {12, 13}, {2, 5}, {8, 11}, {0, 14}, {14, 16},
    {0, 15}, {15, 17},
};
constexpr int kHeadKp[] = {0, 14, 15, 16, 17};  // nose, eyes, ears

struct Skel { int id; float x[kBody18], y[kBody18], c[kBody18]; float head3d[3]; };

struct Config {
    std::string network = kDefaultModel;
    std::string model_root = "/home/j/voyager-sdk/build/";
    std::string labels = "/home/j/voyager-sdk/ax_datasets/labels/coco.names";
    int fps = 60, seconds = 0;   // 0 = run until Esc; --seconds N caps it
    bool headless = false, bodies = true;
    float conf = 0.25f, iou = 0.45f, depth_max = 20.f, head_frac = 0.22f, kp_conf = 30.f;
    int depth_every = 3;  // run depth+skeleton (iGPU) every Nth grab; detect/display run every frame
    int record_fps = 0;   // 0 = auto (camera fps); set to the run's sustained rate for realtime playback
    std::string record, publish;
};

struct Mode { const char* name; sl::RESOLUTION res; int w, h; };
constexpr Mode kModes[] = {
    {"HD1200", sl::RESOLUTION::HD1200, 1920, 1200},
    {"HD1080", sl::RESOLUTION::HD1080, 1920, 1080},
    {"SVGA", sl::RESOLUTION::SVGA, 960, 600},
};

std::string resolve_model_json(const std::string& root, const std::string& net) {
    std::string base = root + net + "/" + net + "/";
    for (int cores : {4, 2, 1}) {
        std::string p = base + std::to_string(cores) + "/model.json";
        if (std::ifstream(p).good()) return p;
    }
    return base + "1/model.json";
}

// ---- thread-safe slot queue (indices into the slot ring) -------------------
class SlotQueue {
public:
    void push(int v) {
        { std::lock_guard<std::mutex> lk(m_); q_.push_back(v); }
        cv_.notify_one();
    }
    // returns false if stopped and empty
    bool pop(int& out, const std::atomic<bool>& stop) {
        std::unique_lock<std::mutex> lk(m_);
        cv_.wait(lk, [&] { return !q_.empty() || stop; });
        if (q_.empty()) return false;
        out = q_.front(); q_.pop_front();
        return true;
    }
    void notify_all_stop() { cv_.notify_all(); }
private:
    std::mutex m_;
    std::condition_variable cv_;
    std::deque<int> q_;
};

// ---- one tracked object (IoU tracker, #8) ----------------------------------
struct Track {
    int id, cls, miss = 0;
    yolo::RawDet box;     // EMA-smoothed box
    float dist = NAN, prev_dist = NAN, vel = NAN, ttc = NAN;
    float wx = NAN, wy = NAN, wz = NAN;   // world-frame position (m)
    bool head_from_skel = false;
    float hx0, hy0, hx1, hy1;             // head keep-out rect (image px)
    float head3d[3] = {NAN, NAN, NAN};
};

class Tracker {
public:
    explicit Tracker(float iou_match) : iou_(iou_match) {}
    // match dets to existing tracks; returns the live track list
    std::vector<Track>& update(std::vector<yolo::RawDet>& dets, double dt) {
        std::vector<bool> used(dets.size(), false);
        for (Track& t : tracks_) {
            int best = -1; float bestiou = iou_;
            for (size_t i = 0; i < dets.size(); ++i)
                if (!used[i] && dets[i].cls == t.cls) {
                    float v = yolo::iou(t.box, dets[i]);
                    if (v > bestiou) { bestiou = v; best = (int)i; }
                }
            if (best >= 0) {
                used[best] = true;
                const float a = 0.5f;  // EMA
                yolo::RawDet& d = dets[best];
                t.box.x0 = a * d.x0 + (1 - a) * t.box.x0;
                t.box.y0 = a * d.y0 + (1 - a) * t.box.y0;
                t.box.x1 = a * d.x1 + (1 - a) * t.box.x1;
                t.box.y1 = a * d.y1 + (1 - a) * t.box.y1;
                t.box.score = d.score; t.miss = 0;
            } else {
                t.miss++;
            }
        }
        // spawn tracks for unmatched detections
        for (size_t i = 0; i < dets.size(); ++i)
            if (!used[i]) tracks_.push_back({next_id_++, dets[i].cls, 0, dets[i]});
        // drop stale
        tracks_.erase(std::remove_if(tracks_.begin(), tracks_.end(),
                          [](const Track& t) { return t.miss > 8; }),
                      tracks_.end());
        last_dt_ = dt;
        return tracks_;
    }
    void update_kinematics(Track& t) {
        if (std::isfinite(t.dist) && std::isfinite(t.prev_dist) && last_dt_ > 1e-3) {
            float v = (t.dist - t.prev_dist) / (float)last_dt_;  // +receding,-approaching
            t.vel = std::isfinite(t.vel) ? 0.6f * t.vel + 0.4f * v : v;
            t.ttc = (t.vel < -0.05f) ? -t.dist / t.vel : NAN;    // s to contact if closing
        }
        t.prev_dist = t.dist;
    }
private:
    std::vector<Track> tracks_;
    float iou_;
    int next_id_ = 1;
    double last_dt_ = 0;
};

// median of finite, positive depth in an image-space patch (DEPTH F32_C1)
float median_depth(const cv::Mat& depth, float sc, float x0, float y0, float x1,
                   float y1, std::vector<float>& scratch) {
    int W = depth.cols, H = depth.rows;
    int px0 = std::clamp((int)(x0 * sc), 0, W - 1), px1 = std::clamp((int)(x1 * sc), 0, W - 1);
    int py0 = std::clamp((int)(y0 * sc), 0, H - 1), py1 = std::clamp((int)(y1 * sc), 0, H - 1);
    if (px1 <= px0 || py1 <= py0) return NAN;
    int sx = std::max(1, (px1 - px0) / 24), sy = std::max(1, (py1 - py0) / 24);
    int n = 0;
    for (int y = py0; y <= py1; y += sy) {
        const float* r = depth.ptr<float>(y);
        for (int x = px0; x <= px1; x += sx) {
            float z = r[x];
            if (std::isfinite(z) && z > 0 && n < (int)scratch.size()) scratch[n++] = z;
        }
    }
    if (n < 6) return NAN;
    std::nth_element(scratch.begin(), scratch.begin() + n / 2, scratch.begin() + n);
    return scratch[n / 2];
}

struct Pinned {  // cudaHostAlloc once, freed once
    void* p = nullptr;
    bool alloc(size_t n) { return cudaHostAlloc(&p, n, cudaHostAllocDefault) == cudaSuccess; }
    ~Pinned() { if (p) cudaFreeHost(p); }
    Pinned() = default;
    Pinned(const Pinned&) = delete;
    Pinned& operator=(const Pinned&) = delete;
};

}  // namespace

int main(int argc, char** argv) {
    // ---- config (#9) -------------------------------------------------------
    Config cfg;
    const Mode* mode = &kModes[0];
    auto farg = [&](int& i) { return std::string(argv[++i]); };
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--mode" && i + 1 < argc) {
            std::string m = farg(i); mode = nullptr;
            for (const Mode& c : kModes) if (m == c.name) mode = &c;
            if (!mode) { std::cerr << "unknown mode " << m << "\n"; return 1; }
        } else if (a == "--fps" && i + 1 < argc) cfg.fps = std::stoi(farg(i));
        else if (a == "--seconds" && i + 1 < argc) cfg.seconds = std::stoi(farg(i));
        else if (a == "--headless") cfg.headless = true;
        else if (a == "--no-bodies") cfg.bodies = false;
        else if (a == "--model" && i + 1 < argc) cfg.network = farg(i);
        else if (a == "--model-root" && i + 1 < argc) cfg.model_root = farg(i);
        else if (a == "--labels" && i + 1 < argc) cfg.labels = farg(i);
        else if (a == "--conf" && i + 1 < argc) cfg.conf = std::stof(farg(i));
        else if (a == "--iou" && i + 1 < argc) cfg.iou = std::stof(farg(i));
        else if (a == "--depth-max" && i + 1 < argc) cfg.depth_max = std::stof(farg(i));
        else if (a == "--head-frac" && i + 1 < argc) cfg.head_frac = std::stof(farg(i));
        else if (a == "--kp-conf" && i + 1 < argc) cfg.kp_conf = std::stof(farg(i));
        else if (a == "--depth-every" && i + 1 < argc) cfg.depth_every = std::stoi(farg(i));
        else if (a == "--record-fps" && i + 1 < argc) cfg.record_fps = std::stoi(farg(i));
        else if (a == "--record" && i + 1 < argc) cfg.record = farg(i);
        else if (a == "--publish" && i + 1 < argc) cfg.publish = farg(i);
        else { std::cerr << "usage: see header\n"; return 1; }
    }
    if (cfg.model_root.back() != '/') cfg.model_root += '/';
    const std::string model_json = resolve_model_json(cfg.model_root, cfg.network);

    // ---- camera: depth + IMU-fused tracking + skeletons --------------------
    sl::Camera cam;
    sl::InitParameters init;
    init.camera_resolution = mode->res;
    init.camera_fps = cfg.fps;
    init.depth_mode = sl::DEPTH_MODE::NEURAL_LIGHT;
    init.coordinate_units = sl::UNIT::METER;
    init.depth_maximum_distance = cfg.depth_max;
    init.depth_stabilization = 1;  // low: depth is gated per-cadence, heavy temporal smoothing hurts
    if (sl::ERROR_CODE e = cam.open(init); e != sl::ERROR_CODE::SUCCESS) {
        std::cerr << "ZED X open failed: " << sl::toString(e)
                  << " (is jetson-av-mission holding the camera?)\n";
        return 1;
    }
    cam.enablePositionalTracking(sl::PositionalTrackingParameters());
    if (cfg.bodies) {
        sl::BodyTrackingParameters bt;
        bt.detection_model = sl::BODY_TRACKING_MODEL::HUMAN_BODY_FAST;
        bt.body_format = sl::BODY_FORMAT::BODY_18;
        bt.enable_tracking = true;
        bt.allow_reduced_precision_inference = true;  // FP16 -> tensor cores/DLA
        if (cam.enableBodyTracking(bt) != sl::ERROR_CODE::SUCCESS) {
            std::cerr << "warn: body tracking unavailable\n";
            cfg.bodies = false;
        }
    }
    // left-camera intrinsics for deprojection (#7), at native resolution
    auto calib = cam.getCameraInformation().camera_configuration.calibration_parameters.left_cam;
    const float fx = calib.fx, fy = calib.fy, ccx = calib.cx, ccy = calib.cy;
    cudaStream_t stream = reinterpret_cast<cudaStream_t>(cam.getCUDAStream());  // #12
    cv::cuda::Stream cvStream = cv::cuda::StreamAccessor::wrapStream(stream);
    std::cout << "ZED X open: S/N " << cam.getCameraInformation().serial_number << " "
              << mode->name << "@" << cfg.fps << " depth+IMU"
              << (cfg.bodies ? "+skeleton(GPU)" : "")
              << "  [depth/skeleton every " << std::max(1, cfg.depth_every)
              << " frames; detect+display every frame]\n";

    // ---- model -------------------------------------------------------------
    auto ctx = axr::to_ptr(axr_create_context());
    auto err = [&] { return axr_last_error_string(AXR_OBJECT(ctx.get())); };
    axrModel* model = axr_load_model(ctx.get(), model_json.c_str());
    if (!model) { std::cerr << "load_model " << model_json << ": " << err() << "\n"; return 1; }
    axrTensorInfo in_info = axr_get_model_input(model, 0);
    const int batch = in_info.dims[0], tH = in_info.dims[1], tW = in_info.dims[2],
              tC = in_info.dims[3];
    const int padT = in_info.padding[1][0], padL = in_info.padding[2][0];
    const size_t in_bytes = axr_tensor_size(&in_info);
    if (batch != 1) {
        std::cerr << "fusion sample expects a 1-core (batch=1) artifact; got batch=" << batch
                  << ". Use a model whose 1/ build exists, or zedx_metis_infer for batch-4.\n";
        // not fatal: we still run, using slot 0 only
    }
    axrConnection* conn = axr_device_connect(ctx.get(), nullptr, batch, nullptr);
    if (!conn) { std::cerr << "connect: " << err() << "\n"; return 1; }

    const size_t n_out = axr_num_model_outputs(model);
    std::vector<axrTensorInfo> out_info(n_out);
    for (size_t i = 0; i < n_out; ++i) out_info[i] = axr_get_model_output(model, i);

    // ---- input buffers: dma-heap (#1) with host fallback -------------------
    bool use_dmabuf = false;
#if HAVE_AXDMABUF
    std::vector<std::unique_ptr<axelera::DmaBuf>> dmabufs;
    try {
        for (int i = 0; i < kRing; ++i)
            dmabufs.push_back(std::make_unique<axelera::DmaBuf>(axelera::DmaBuf::alloc(in_bytes, true)));
        use_dmabuf = true;
    } catch (const std::exception& e) {
        std::cerr << "warn: dma-heap alloc failed (" << e.what() << "); host-ptr input\n";
        use_dmabuf = false;
    }
#endif
    std::string props = std::string("input_dmabuf=") + (use_dmabuf ? "1" : "0") +
                        ";double_buffer=1;num_sub_devices=" + std::to_string(batch) +
                        ";aipu_cores=" + std::to_string(batch);
    axrModelInstance* inst = axr_load_model_instance(
        conn, model, axr_create_properties(ctx.get(), props.c_str()));
    if (!inst) { std::cerr << "instance: " << err() << "\n"; return 1; }
    std::cout << "model: " << cfg.network << " (" << (n_out == 6 ? "yolov8" : "yolov5")
              << ", " << (use_dmabuf ? "dma-heap" : "host") << " input)\n";

    // ---- geometry (one decoder, LUTs built once; buffers passed per slot) ---
    yolo::Decoder dec(out_info, cfg.conf, cfg.iou, 300, mode->w, mode->h);
    const int lbW = dec.lbW(), lbH = dec.lbH(), lbX = dec.lbX(), lbY = dec.lbY();
    const int dispW = 800, dispH = (int)std::round(mode->h * 800.0 / mode->w);
    const float dsp = (float)dispW / mode->w;          // native -> display scale
    const int depthW = 640, depthH = mode->h * 640 / mode->w;
    const float depthSc = (float)depthW / mode->w;     // native -> depth scale

    // ---- device scratch int8 tensor (preset pad+gray once) -----------------
    int8_t* d_scratch = nullptr;
    cudaMalloc(&d_scratch, in_bytes);
    {
        std::vector<int8_t> preset(in_bytes, (int8_t)in_info.zero_point);
        for (int y = 0; y < kInputSize; ++y)
            std::memset(preset.data() + ((padT + y) * tW + padL) * tC, 114 - 128,
                        (size_t)kInputSize * tC);
        cudaMemcpy(d_scratch, preset.data(), in_bytes, cudaMemcpyHostToDevice);
    }

    // ---- per-slot ring -----------------------------------------------------
    struct Slot {
        std::vector<std::vector<int8_t>> out;   // decoded from these
        std::vector<axrArgument> out_args;
        std::vector<int8_t> host_in;             // used when !use_dmabuf
        axrArgument in_arg{nullptr, 0, 0, 0};
        cv::Mat vis;                             // display BGRA (dispW x dispH)
        cv::Mat depth;                           // DEPTH F32_C1 (depthW x depthH)
        float ax = NAN, ay = NAN, az = NAN, tx = 0, ty = 0, tz = 0, gyro = 0;
        int conf = -1;
        float Rt[12] = {1,0,0,0, 0,1,0,0, 0,0,1,0};  // world_T_cam (row-major 3x4)
        std::vector<Skel> skels;
        int nskel = 0;
        bool depth_fresh = false;   // depth/skeletons recomputed this frame vs carried forward
        double stamp = 0;
    };
    std::vector<Slot> slots(kRing);
    std::vector<cv::cuda::GpuMat> g_disp(kRing);
    std::vector<Pinned> vis_pin(kRing);
    const size_t vis_bytes = (size_t)dispW * dispH * 4;
    for (int i = 0; i < kRing; ++i) {
        Slot& s = slots[i];
        s.out.resize(n_out); s.out_args.resize(n_out);
        for (size_t k = 0; k < n_out; ++k) {
            s.out[k].resize(axr_tensor_size(&out_info[k]));
            s.out_args[k] = {s.out[k].data(), 0, 0, 0};
        }
        if (use_dmabuf) {
#if HAVE_AXDMABUF
            s.in_arg = {nullptr, dmabufs[i]->get_dmabuf_handle(), 0, 0};
#endif
        } else {
            s.host_in.resize(in_bytes);
            s.in_arg = {s.host_in.data(), 0, 0, 0};
        }
        g_disp[i].create(dispH, dispW, CV_8UC4);
        vis_pin[i].alloc(vis_bytes);
        s.vis = cv::Mat(dispH, dispW, CV_8UC4, vis_pin[i].p);
        s.depth.create(depthH, depthW, CV_32FC1);
        s.skels.resize(kMaxBodies);
    }

    // ---- output: record + publish (#10) ------------------------------------
    // Annotated frames are produced whenever we display OR record; the on-screen
    // window is the only thing gated by !headless. So --headless --record works.
    const bool want_vis = !cfg.headless || !cfg.record.empty();
    cv::VideoWriter writer;
    bool rec_nvenc = false;
    if (!cfg.record.empty()) {
        // tag at the run's sustained rate for realtime playback (0 = auto = camera fps).
        // record is render-bound (~30 for fusion) even with NVENC; auto-tag 30 so
        // playback is ~realtime. Pass --record-fps to match a measured rate exactly.
        const int rec_fps = std::min(cfg.record_fps > 0 ? cfg.record_fps : 30, 120);
        // OpenCV feeds BGR via appsrc; explicit caps drive the hardware NVENC path:
        // BGR -> BGRx (videoconvert) -> NV12 in NVMM (nvvidconv) -> nvv4l2h264enc.
        std::string gst =
            "appsrc ! video/x-raw,format=BGR ! queue ! videoconvert ! "
            "video/x-raw,format=BGRx ! nvvidconv ! video/x-raw(memory:NVMM),format=NV12 ! "
            "nvv4l2h264enc maxperf-enable=1 insert-sps-pps=1 ! h264parse ! qtmux ! filesink location=" +
            cfg.record;
        writer.open(gst, cv::CAP_GSTREAMER, 0, rec_fps, {dispW, dispH}, true);
        rec_nvenc = writer.isOpened();
        if (!rec_nvenc)  // software fallback (no GStreamer/NVENC)
            writer.open(cfg.record, cv::VideoWriter::fourcc('m', 'p', '4', 'v'),
                        rec_fps, {dispW, dispH});
        std::cout << "record: " << (writer.isOpened() ? cfg.record : "FAILED") << " ("
                  << (rec_nvenc ? "NVENC/gst" : "software mp4v") << ") @" << rec_fps
                  << "fps " << dispW << "x" << dispH << "\n";
    }
    int sock = -1; sockaddr_in dest{};
    if (!cfg.publish.empty()) {
        auto c = cfg.publish.find(':');
        std::string host = cfg.publish.substr(0, c);
        int port = std::stoi(cfg.publish.substr(c + 1));
        sock = socket(AF_INET, SOCK_DGRAM, 0);
        dest.sin_family = AF_INET; dest.sin_port = htons(port);
        inet_pton(AF_INET, host.c_str(), &dest.sin_addr);
        std::cout << "publish: udp " << cfg.publish << "\n";
    }

    // ---- pipeline queues + ring lifecycle ----------------------------------
    SlotQueue freeq, inferq, renderq;
    for (int i = 0; i < kRing; ++i) freeq.push(i);
    std::atomic<bool> stop{false};
    auto labels = yolo::load_labels(cfg.labels.c_str());
    auto palette = yolo::make_palette(kClasses);
    auto t0 = std::chrono::steady_clock::now();
    auto now_s = [&] {
        return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    };

    // ===== STAGE 1: capture (grab, GPU preprocess, depth, pose, bodies) =====
    std::thread capture([&] {
        sl::Mat img, depth;
        sl::Pose pose;
        sl::SensorsData sens;
        sl::Bodies bodies;
        if (cfg.bodies) {
            sl::BodyTrackingRuntimeParameters br; br.detection_confidence_threshold = 40;
            cam.setBodyTrackingRuntimeParameters(br);
        }
        sl::RuntimeParameters rt; rt.confidence_threshold = 90;
        // Cadence decoupling: grab + detect + display + pose run EVERY frame; the
        // heavy iGPU work (NEURAL_LIGHT depth net inside grab(), and the body net
        // in retrieveBodies()) runs only every Nth grab. Last depth + skeletons
        // carry forward; the IoU tracker smooths distance/velocity/TTC between
        // updates, so detection/display rise toward the camera/NPU rate while
        // depth+skeleton tick at ~rate/N   all features kept.
        const int N = std::max(1, cfg.depth_every);
        cv::Mat last_depth = cv::Mat::zeros(depthH, depthW, CV_32FC1);
        std::vector<Skel> last_skels(kMaxBodies);
        int last_nskel = 0;
        long idx = 0;
        while (!stop) {
            int si;
            if (!freeq.pop(si, stop)) break;
            Slot& s = slots[si];
            const bool depth_frame = (idx % N == 0);
            rt.enable_depth = depth_frame;  // skips the depth net entirely on off-frames
            if (cam.grab(rt) != sl::ERROR_CODE::SUCCESS) { freeq.push(si); continue; }
            // left image on GPU; wrap as GpuMat (no copy)
            cam.retrieveImage(img, sl::VIEW::LEFT, sl::MEM::GPU, sl::Resolution(0, 0), stream);
            cv::cuda::GpuMat gFull((int)img.getHeight(), (int)img.getWidth(), CV_8UC4,
                                   img.getPtr<sl::uchar1>(sl::MEM::GPU),
                                   img.getStepBytes(sl::MEM::GPU));
            // (#1) letterbox+quantize on the GPU into the device scratch tensor
            launch_letterbox_quantize(d_scratch, (const uchar4*)gFull.ptr(),
                                      (int)img.getWidth(), (int)img.getHeight(),
                                      gFull.step, tW, tC, padT, padL, lbW, lbH, lbX, lbY,
                                      stream);
            // (#3) GPU-downscale the annotated frame, then download only 800xH
            // (needed for display OR recording)
            if (want_vis) {
                cv::cuda::resize(gFull, g_disp[si], {dispW, dispH}, 0, 0, cv::INTER_LINEAR,
                                 cvStream);
                g_disp[si].download(s.vis, cvStream);
            }
            cudaStreamSynchronize(stream);
            // copy quantized tensor into this slot's NPU input (dma-heap or host)
            if (use_dmabuf) {
#if HAVE_AXDMABUF
                auto acc = dmabufs[si]->access();     // CPU/NPU coherency window
                cudaMemcpy(acc.data(), d_scratch, in_bytes, cudaMemcpyDeviceToHost);
#endif
            } else {
                cudaMemcpy(s.host_in.data(), d_scratch, in_bytes, cudaMemcpyDeviceToHost);
            }
            // pose + world_T_cam (#7) + IMU accel (gizmo)   cheap, every frame
            s.conf = -1;
            if (cam.getPosition(pose, sl::REFERENCE_FRAME::WORLD) ==
                sl::POSITIONAL_TRACKING_STATE::OK) {
                auto t = pose.getTranslation(); auto R = pose.getRotationMatrix();
                s.tx = t.x; s.ty = t.y; s.tz = t.z; s.conf = pose.pose_confidence;
                for (int r = 0; r < 3; ++r) {
                    s.Rt[r * 4 + 0] = R(r, 0); s.Rt[r * 4 + 1] = R(r, 1);
                    s.Rt[r * 4 + 2] = R(r, 2);
                    s.Rt[r * 4 + 3] = (r == 0 ? t.x : r == 1 ? t.y : t.z);
                }
            }
            if (cam.getSensorsData(sens, sl::TIME_REFERENCE::IMAGE) == sl::ERROR_CODE::SUCCESS) {
                auto w = sens.imu.angular_velocity;
                s.gyro = std::sqrt(w.x * w.x + w.y * w.y + w.z * w.z);
                auto a = sens.imu.linear_acceleration;
                s.ax = a.x; s.ay = a.y; s.az = a.z;
            }
            // heavy perception only on depth frames; else reuse the last results
            if (depth_frame) {
                // (#2) depth F32_C1 at reduced res; computed in this grab()
                cam.retrieveMeasure(depth, sl::MEASURE::DEPTH, sl::MEM::CPU,
                                    sl::Resolution(depthW, depthH));
                std::memcpy(last_depth.data, depth.getPtr<sl::float1>(),
                            (size_t)depthW * depthH * sizeof(float));
                // skeletons (#5/#6)   only refresh when the body net produced new data
                if (cfg.bodies && cam.retrieveBodies(bodies) == sl::ERROR_CODE::SUCCESS &&
                    bodies.is_new) {
                    last_nskel = 0;
                    for (const sl::BodyData& b : bodies.body_list) {
                        if (last_nskel >= kMaxBodies ||
                            b.keypoint_2d.size() < (size_t)kBody18) continue;
                        Skel& sk = last_skels[last_nskel++];
                        sk.id = b.id;
                        for (int k = 0; k < kBody18; ++k) {
                            sk.x[k] = b.keypoint_2d[k].x; sk.y[k] = b.keypoint_2d[k].y;
                            sk.c[k] = k < (int)b.keypoint_confidence.size()
                                          ? b.keypoint_confidence[k] : 0.f;
                        }
                        sk.head3d[0] = sk.head3d[1] = sk.head3d[2] = NAN;
                        if (!b.keypoint.empty() && std::isfinite(b.keypoint[0].z)) {
                            sk.head3d[0] = b.keypoint[0].x; sk.head3d[1] = b.keypoint[0].y;
                            sk.head3d[2] = b.keypoint[0].z;
                        }
                    }
                }
            }
            // hand the latest perception to this slot (carried forward off-frames)
            std::memcpy(s.depth.data, last_depth.data,
                        (size_t)depthW * depthH * sizeof(float));
            s.nskel = last_nskel;
            for (int i = 0; i < last_nskel; ++i) s.skels[i] = last_skels[i];
            s.depth_fresh = depth_frame;
            s.stamp = now_s();
            ++idx;
            inferq.push(si);
        }
        inferq.notify_all_stop();
    });

    // ===== STAGE 2: inference (Metis) =======================================
    std::thread infer([&] {
        while (!stop) {
            int si;
            if (!inferq.pop(si, stop)) break;
            Slot& s = slots[si];
            if (axr_run_model_instance(inst, &s.in_arg, 1, s.out_args.data(), n_out)
                != AXR_SUCCESS) {
                std::cerr << "run: " << err() << "\n";
                stop = true; freeq.notify_all_stop(); break;
            }
            renderq.push(si);
        }
        renderq.notify_all_stop();
    });

    // ===== STAGE 3: render (decode, fuse, track, draw) ======================
    if (!cfg.headless) {
        cv::namedWindow("ZED X + Metis fusion", cv::WINDOW_NORMAL);
        cv::resizeWindow("ZED X + Metis fusion", dispW, dispH);
    }
    Tracker tracker(0.3f);
    std::vector<float> scratch(4096);
    std::vector<yolo::RawDet> dets;
    long frames = 0;
    double prev_stamp = 0;
    char text[192];

    while (!stop && (cfg.seconds <= 0 || now_s() < cfg.seconds)) {
        int si;
        if (!renderq.pop(si, stop)) break;
        Slot& s = slots[si];
        dec.decode(0, s.out, dets);  // shared decoder, this slot's buffers
        double dt = s.stamp - prev_stamp; prev_stamp = s.stamp;
        auto& tracks = tracker.update(dets, dt > 0 ? dt : 1.0 / std::max(1, cfg.fps));

        for (Track& t : tracks) {
            if (t.miss > 0) continue;  // only freshly-matched this frame
            // distance from a central patch (#2)
            float bw = t.box.x1 - t.box.x0, bh = t.box.y1 - t.box.y0;
            t.dist = median_depth(s.depth, depthSc, t.box.x0 + 0.3f * bw,
                                  t.box.y0 + 0.3f * bh, t.box.x1 - 0.3f * bw,
                                  t.box.y1 - 0.3f * bh, scratch);
            tracker.update_kinematics(t);
            // world-frame position via deproject + pose (#7)
            t.wx = t.wy = t.wz = NAN;
            if (std::isfinite(t.dist)) {
                float u = 0.5f * (t.box.x0 + t.box.x1), v = 0.5f * (t.box.y0 + t.box.y1);
                float Xc = (u - ccx) * t.dist / fx, Yc = (v - ccy) * t.dist / fy, Zc = t.dist;
                t.wx = s.Rt[0]*Xc + s.Rt[1]*Yc + s.Rt[2]*Zc + s.Rt[3];
                t.wy = s.Rt[4]*Xc + s.Rt[5]*Yc + s.Rt[6]*Zc + s.Rt[7];
                t.wz = s.Rt[8]*Xc + s.Rt[9]*Yc + s.Rt[10]*Zc + s.Rt[11];
            }
            // head keep-out: default top-fraction; refined by a matched skeleton (#5/#6)
            t.head_from_skel = false;
            t.hx0 = t.box.x0; t.hy0 = t.box.y0; t.hx1 = t.box.x1;
            t.hy1 = t.box.y0 + cfg.head_frac * bh;
            t.head3d[0] = t.head3d[1] = t.head3d[2] = NAN;
            if (t.cls == kPersonClass) {
                for (int i = 0; i < s.nskel; ++i) {
                    const Skel& sk = s.skels[i];
                    // body center vs box overlap (cheap match: nose/neck inside box)
                    float nx = sk.x[1], ny = sk.y[1];  // neck
                    if (sk.c[1] >= cfg.kp_conf && nx >= t.box.x0 && nx <= t.box.x1 &&
                        ny >= t.box.y0 && ny <= t.box.y1) {
                        float minx = 1e9f, miny = 1e9f, maxx = -1e9f, maxy = -1e9f; int nfound = 0;
                        for (int k : kHeadKp)
                            if (sk.c[k] >= cfg.kp_conf && sk.x[k] > 0 && sk.y[k] > 0) {
                                minx = std::min(minx, sk.x[k]); maxx = std::max(maxx, sk.x[k]);
                                miny = std::min(miny, sk.y[k]); maxy = std::max(maxy, sk.y[k]);
                                ++nfound;
                            }
                        if (nfound >= 2) {
                            float mx = 0.25f * (maxx - minx) + 6, my = 0.4f * (maxy - miny) + 6;
                            t.hx0 = minx - mx; t.hy0 = miny - my;
                            t.hx1 = maxx + mx; t.hy1 = maxy + my;
                            t.head_from_skel = true;
                        }
                        for (int j = 0; j < 3; ++j) t.head3d[j] = sk.head3d[j];
                        break;
                    }
                }
            }
        }

        // ---- draw (for display and/or recording) ----
        if (want_vis) {
            cv::Mat& vis = s.vis;
            for (const Track& t : tracks) {
                if (t.miss > 0) continue;
                const cv::Scalar& col = palette[t.cls];
                cv::Point p0((int)(t.box.x0 * dsp), (int)(t.box.y0 * dsp));
                cv::Point p1((int)(t.box.x1 * dsp), (int)(t.box.y1 * dsp));
                cv::rectangle(vis, p0, p1, col, 2);
                int n = snprintf(text, sizeof text, "%s#%d %.2f", labels[t.cls].c_str(),
                                 t.id, t.box.score);
                if (std::isfinite(t.dist)) n += snprintf(text + n, sizeof text - n, " %.1fm", t.dist);
                if (std::isfinite(t.ttc)) snprintf(text + n, sizeof text - n, " ttc%.1fs", t.ttc);
                cv::putText(vis, text, {p0.x, p0.y - 5}, cv::FONT_HERSHEY_SIMPLEX, 0.5, col, 1);
                if (t.cls == kPersonClass) {  // hot head keep-out
                    cv::rectangle(vis, {(int)(t.hx0 * dsp), (int)(t.hy0 * dsp)},
                                  {(int)(t.hx1 * dsp), (int)(t.hy1 * dsp)}, {0, 0, 255, 255}, 2);
                    if (std::isfinite(t.head3d[2])) {
                        snprintf(text, sizeof text, "HEAD %.1fm", t.head3d[2]);
                        cv::putText(vis, text, {(int)(t.hx0 * dsp) + 3, (int)(t.hy0 * dsp) - 4},
                                    cv::FONT_HERSHEY_SIMPLEX, 0.45, {0, 0, 255, 255}, 1);
                    }
                }
            }
            // skeletons
            auto kp_ok = [&](const Skel& sk, int k) {
                return sk.c[k] >= cfg.kp_conf && std::isfinite(sk.x[k]) && std::isfinite(sk.y[k]) &&
                       sk.x[k] >= 1.f && sk.y[k] >= 1.f && sk.x[k] < mode->w && sk.y[k] < mode->h;
            };
            for (int i = 0; i < s.nskel; ++i) {
                const Skel& sk = s.skels[i];
                for (const auto& bn : kBones)
                    if (kp_ok(sk, bn[0]) && kp_ok(sk, bn[1]))
                        cv::line(vis, {(int)(sk.x[bn[0]] * dsp), (int)(sk.y[bn[0]] * dsp)},
                                 {(int)(sk.x[bn[1]] * dsp), (int)(sk.y[bn[1]] * dsp)},
                                 {255, 255, 0, 255}, 2);
                for (int k = 0; k < kBody18; ++k)
                    if (kp_ok(sk, k))
                        cv::circle(vis, {(int)(sk.x[k] * dsp), (int)(sk.y[k] * dsp)}, 3,
                                   {0, 255, 255, 255}, -1);
            }
            // IMU accel 3-vector gizmo (bottom-left)
            {
                cv::Point2f o(70.f, (float)dispH - 70.f);
                const cv::Point2f dx(0.866f, 0.5f), dy(-0.866f, 0.5f), dz(0.f, -1.f);
                auto P = [&](float vx, float vy, float vz, float sc) {
                    return cv::Point((int)(o.x + sc*(vx*dx.x+vy*dy.x+vz*dz.x)),
                                     (int)(o.y + sc*(vx*dx.y+vy*dy.y+vz*dz.y)));
                };
                cv::circle(vis, o, 42, {0, 0, 0, 160}, -1);
                cv::arrowedLine(vis, o, P(1,0,0,30), {60,60,255,255}, 1, 8, 0, 0.3);
                cv::arrowedLine(vis, o, P(0,1,0,30), {60,255,60,255}, 1, 8, 0, 0.3);
                cv::arrowedLine(vis, o, P(0,0,1,30), {255,160,60,255}, 1, 8, 0, 0.3);
                if (std::isfinite(s.ax))
                    cv::arrowedLine(vis, o, P(s.ax, s.ay, s.az, 2.8f), {255,255,255,255}, 2, 8, 0, 0.25);
            }
            snprintf(text, sizeof text, "pose %.2f %.2f %.2f m  conf %d  gyro %.0f  trk %zu  %.1f FPS",
                     s.tx, s.ty, s.tz, s.conf, s.gyro, tracks.size(), frames / std::max(1e-3, now_s()));
            cv::putText(vis, text, {10, 22}, cv::FONT_HERSHEY_SIMPLEX, 0.5, {0, 255, 255, 255}, 1);
            if (writer.isOpened()) {
                cv::Mat bgr; cv::cvtColor(vis, bgr, cv::COLOR_BGRA2BGR); writer.write(bgr);
            }
            if (!cfg.headless) {                 // on-screen window only when not headless
                cv::imshow("ZED X + Metis fusion", vis);
                if (cv::waitKey(1) == 27) stop = true;
            }
        }

        // ---- publish detections (#10) ----
        if (sock >= 0) {
            std::string msg = "{\"t\":" + std::to_string(s.stamp) + ",\"obj\":[";
            bool first = true;
            for (const Track& t : tracks) {
                if (t.miss > 0) continue;
                if (!first) msg += ",";
                first = false;
                char b[256];
                snprintf(b, sizeof b,
                         "{\"id\":%d,\"cls\":%d,\"score\":%.2f,\"dist\":%.2f,"
                         "\"world\":[%.2f,%.2f,%.2f],\"vel\":%.2f}",
                         t.id, t.cls, t.box.score, t.dist, t.wx, t.wy, t.wz, t.vel);
                msg += b;
            }
            msg += "]}";
            sendto(sock, msg.data(), msg.size(), 0, (sockaddr*)&dest, sizeof(dest));
        }

        frames++;
        if (frames % 120 == 0)
            std::cout << frames << " frames, " << frames / now_s() << " FPS, "
                      << tracks.size() << " tracks\n";
        freeq.push(si);
    }

    // ---- shutdown ----------------------------------------------------------
    stop = true;
    freeq.notify_all_stop(); inferq.notify_all_stop(); renderq.notify_all_stop();
    capture.join(); infer.join();
    double secs = now_s();
    std::cout << frames << " frames in " << secs << "s (end-to-end " << frames / secs << " FPS)\n";
    if (writer.isOpened()) writer.release();
    if (sock >= 0) close(sock);
    cudaFree(d_scratch);
    if (cfg.bodies) cam.disableBodyTracking();
    cam.disablePositionalTracking();
    cam.close();
    return 0;
}
