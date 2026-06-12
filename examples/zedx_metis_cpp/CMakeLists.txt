# examples/zedx_metis_cpp   ZED X -> Metis C++ samples.
# Build: cmake -B build && cmake --build build
# axruntime comes from the av-env wheel install; rpath baked so no LD_LIBRARY_PATH.
# The fusion sample adds a CUDA preprocess kernel (preprocess.cu) and the
# Axelera dma-heap allocator (libaxldev) for zero-staging NPU input.
cmake_minimum_required(VERSION 3.18)
project(zedx_metis_samples CXX CUDA)
set(CMAKE_CXX_STANDARD 20)        # AxeleraDmaBuf.hpp uses std::span/dynamic_extent
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  set(CMAKE_CUDA_ARCHITECTURES 87)   # Orin NX = sm_87
endif()
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(AXELERA_SITE /opt/av-env/lib/python3.10/site-packages)
set(ENV{PKG_CONFIG_PATH} "${AXELERA_SITE}/axelera/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")
find_package(PkgConfig REQUIRED)
pkg_check_modules(AXR REQUIRED axruntime)

find_package(zed REQUIRED)
find_package(CUDA ${ZED_CUDA_VERSION} REQUIRED)
find_package(OpenCV REQUIRED COMPONENTS core imgproc highgui cudawarping cudaimgproc)

# common wiring applied to every target
function(configure_sample tgt)
  target_include_directories(${tgt} PRIVATE
    ${AXR_INCLUDE_DIRS} ${ZED_INCLUDE_DIRS} ${CUDA_INCLUDE_DIRS} ${OpenCV_INCLUDE_DIRS})
  target_link_directories(${tgt} PRIVATE
    ${AXR_LIBRARY_DIRS} ${ZED_LIBRARY_DIR})
  target_link_libraries(${tgt} PRIVATE
    ${AXR_LIBRARIES} ${ZED_LIBRARIES} ${CUDA_LIBRARIES} ${OpenCV_LIBS} pthread)
  set_target_properties(${tgt} PROPERTIES
    BUILD_RPATH "${AXELERA_SITE}/axelera/lib;${AXELERA_SITE}/axelera_runtime.libs")
endfunction()

# lean detector (CPU preprocess, no CUDA kernel needed)
add_executable(zedx_metis_infer zedx_metis_infer.cpp)
configure_sample(zedx_metis_infer)

# full fusion: CUDA preprocess kernel + dma-heap input (libaxldev)
add_executable(zedx_metis_fusion zedx_metis_fusion.cpp preprocess.cu)
configure_sample(zedx_metis_fusion)
target_link_libraries(zedx_metis_fusion PRIVATE axldev)
