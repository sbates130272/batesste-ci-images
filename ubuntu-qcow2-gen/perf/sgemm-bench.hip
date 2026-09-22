// sgemm-bench.hip
//
// A validated FP32 GEMM on the guest's GPU, timed, printing GFLOP/s.
//
// Built and run inside the guest by scripts/perf-harness.sh once amdgpu has
// bound to the rocjitsu emulated gfx1250 over vfio-user. It is the compute
// half of this repo's qualification boot: the guest image's own checks run in
// a probe boot with no vfio-user device, so they can assert that the right
// driver is installed and nothing about whether the device actually computes.
//
// BUILD -- -O2 matters, see "no scratch" below:
//
//     hipcc -O2 --offload-arch=gfx1250 -o sgemm-bench sgemm-bench.hip
//
// RUN -- needs /dev/kfd, which is root:render:
//
//     sudo ./sgemm-bench [iters]
//
// EXIT CODES
//     0  validated, and a GFLOP/s figure was printed
//     1  a HIP API call failed
//     3  the result did not match the CPU reference
//     4  the build is unsuitable -- the kernel needs scratch; see below
//
// WHY NOT rocBLAS
//     Not for want of the package. The rocjitsu guest flavour installs
//     amdrocm-blas-dev, which in the therock stream is headers and no shared
//     library (see consumers/rocm-xio-rocjitsu.md), and adding the runtime
//     amdrocm-blas alongside it would be a fair-sized but perfectly
//     affordable addition to the disk.
//
//     The blocker is the scratch limitation below, and it is not negotiable.
//     rocBLAS dispatches Tensile-generated assembly kernels chosen at run
//     time from a library of thousands; their register and scratch use is a
//     property of the shipped kernel, not of how this file is compiled, and
//     a great many of them carry a non-zero private segment. There is no
//     build flag that makes rocBLAS scratch-free, so on this device it would
//     work or not work depending on which kernel the heuristic picked for a
//     given shape -- a benchmark whose success is a lottery is worse than no
//     benchmark. Hence a hand-written kernel whose scratch use is asserted.
//
//     The consolation is that the number is better for it: it is a property
//     of the emulator and the driver path rather than of AMD's BLAS tuning,
//     which is what is worth trending here anyway. This runs on an
//     instruction-level emulator, where a library's tile selection is noise
//     next to the cost of interpreting the dispatch.
//
// WHY NO SCRATCH
//     On rocjitsu's emulated gfx1250 any kernel with a non-zero private
//     (scratch) segment fails -- see rocjitsu-scratch-repro.hip in
//     ubuntu-rocm-rocjitsu, which exists to demonstrate exactly that. The
//     kernel below keeps every intermediate in registers and uses no local
//     arrays, so at -O2 it comes out with a zero private segment. At -O0 the
//     compiler spills the kernel arguments and every kernel gets scratch,
//     which is why the check below is a runtime assertion on
//     hipFuncAttributes rather than a comment asking the caller to remember.
//
// STABLE OUTPUT CONTRACT
//     The harness greps these; keep the shapes if you change the wording.
//
//         sgemm-bench: device=... arch=...
//         sgemm-bench: m=128 n=128 k=128 iters=8
//         sgemm-bench: private_segment_bytes=0
//         sgemm-bench: max_absolute_error=... failures=0
//         sgemm-bench: seconds_per_iter=... gflops=...
//         sgemm-bench: PASS

#include <hip/hip_runtime.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

// The upstream qualification contract's shape: FP32, column-major-agnostic,
// non-transposed, alpha 1 beta 0, deterministic inputs. Small, because every
// instruction here is interpreted -- 128^3 is already seconds per iteration.
constexpr int kM = 128;
constexpr int kN = 128;
constexpr int kK = 128;

// Loose enough for FP32 accumulation over 128 terms in a different order than
// the reference, tight enough that a genuinely wrong result cannot slip by.
constexpr float kTolerance = 1e-3f;

#define HIP_CHECK(expr)                                                       \
    do {                                                                      \
        hipError_t err_ = (expr);                                             \
        if (err_ != hipSuccess) {                                             \
            std::fprintf(stderr, "sgemm-bench: %s failed: %s\n", #expr,       \
                         hipGetErrorString(err_));                            \
            return 1;                                                         \
        }                                                                     \
    } while (0)

// One output element per thread, accumulated in a register. No __shared__
// tiling: LDS would be faster on real silicon and is irrelevant on an
// emulator, and leaving it out keeps the register footprint low enough that
// the private segment stays at zero.
__global__ void sgemm(const float* __restrict__ a, const float* __restrict__ b,
                      float* __restrict__ c, int m, int n, int k) {
    const int row = blockIdx.y * blockDim.y + threadIdx.y;
    const int col = blockIdx.x * blockDim.x + threadIdx.x;
    if (row >= m || col >= n) {
        return;
    }
    float acc = 0.0f;
    for (int i = 0; i < k; ++i) {
        acc += a[row * k + i] * b[i * n + col];
    }
    c[row * n + col] = acc;
}

int main(int argc, char** argv) {
    int iters = 8;
    if (argc > 1) {
        iters = std::atoi(argv[1]);
        if (iters < 1) {
            std::fprintf(stderr, "sgemm-bench: iters must be >= 1\n");
            return 1;
        }
    }

    hipDeviceProp_t prop{};
    HIP_CHECK(hipGetDeviceProperties(&prop, 0));
    std::printf("sgemm-bench: device=%s arch=%s\n", prop.name, prop.gcnArchName);
    std::printf("sgemm-bench: m=%d n=%d k=%d iters=%d\n", kM, kN, kK, iters);

    // Deterministic inputs, and deliberately not random: a trend that moves
    // because the data moved is not a trend. Values are small and exactly
    // representable so the reference and the device agree to within rounding
    // of the accumulation order alone.
    std::vector<float> ha(static_cast<size_t>(kM) * kK);
    std::vector<float> hb(static_cast<size_t>(kK) * kN);
    std::vector<float> hc(static_cast<size_t>(kM) * kN, 0.0f);
    for (int r = 0; r < kM; ++r) {
        for (int i = 0; i < kK; ++i) {
            ha[static_cast<size_t>(r) * kK + i] =
                static_cast<float>((r + i) % 7) * 0.25f;
        }
    }
    for (int i = 0; i < kK; ++i) {
        for (int col = 0; col < kN; ++col) {
            hb[static_cast<size_t>(i) * kN + col] =
                static_cast<float>((i * 2 + col) % 5) * 0.5f;
        }
    }

    float *da = nullptr, *db = nullptr, *dc = nullptr;
    HIP_CHECK(hipMalloc(&da, ha.size() * sizeof(float)));
    HIP_CHECK(hipMalloc(&db, hb.size() * sizeof(float)));
    HIP_CHECK(hipMalloc(&dc, hc.size() * sizeof(float)));
    HIP_CHECK(hipMemcpy(da, ha.data(), ha.size() * sizeof(float),
                        hipMemcpyHostToDevice));
    HIP_CHECK(hipMemcpy(db, hb.data(), hb.size() * sizeof(float),
                        hipMemcpyHostToDevice));

    // 16x16 threads: 256 per block, the shape that keeps this kernel's
    // register use low. Not tuned -- on an emulator the block shape decides
    // how many dispatches there are, not how fast the hardware runs.
    const dim3 block(16, 16);
    const dim3 grid((kN + block.x - 1) / block.x, (kM + block.y - 1) / block.y);

    // The scratch assertion, before anything is timed. A non-zero private
    // segment means the build is unsuitable and the run would either hang or
    // return untouched memory, which is a far more confusing failure.
    hipFuncAttributes attr{};
    HIP_CHECK(hipFuncGetAttributes(&attr, reinterpret_cast<const void*>(sgemm)));
    std::printf("sgemm-bench: private_segment_bytes=%zu\n",
                static_cast<size_t>(attr.localSizeBytes));
    if (attr.localSizeBytes != 0) {
        std::fprintf(stderr,
                     "sgemm-bench: kernel needs %zu bytes of scratch; rocjitsu's "
                     "emulated gfx1250 cannot run it. Rebuild with -O2.\n",
                     static_cast<size_t>(attr.localSizeBytes));
        return 4;
    }

    // Warm-up, and the run that gets validated. Doing both in one pass means
    // the timed loop below is never the first dispatch -- on this path the
    // first one pays for code-object load and queue setup, which is minutes,
    // not microseconds, and would swamp the measurement.
    hipLaunchKernelGGL(sgemm, grid, block, 0, 0, da, db, dc, kM, kN, kK);
    HIP_CHECK(hipGetLastError());
    HIP_CHECK(hipDeviceSynchronize());
    HIP_CHECK(hipMemcpy(hc.data(), dc, hc.size() * sizeof(float),
                        hipMemcpyDeviceToHost));

    double max_abs_error = 0.0;
    long failures = 0;
    for (int r = 0; r < kM; ++r) {
        for (int col = 0; col < kN; ++col) {
            double ref = 0.0;
            for (int i = 0; i < kK; ++i) {
                ref += static_cast<double>(ha[static_cast<size_t>(r) * kK + i]) *
                       static_cast<double>(hb[static_cast<size_t>(i) * kN + col]);
            }
            const double got =
                static_cast<double>(hc[static_cast<size_t>(r) * kN + col]);
            const double err = std::fabs(got - ref);
            if (err > max_abs_error) {
                max_abs_error = err;
            }
            if (err > kTolerance) {
                ++failures;
            }
        }
    }
    std::printf("sgemm-bench: max_absolute_error=%.6g failures=%ld\n",
                max_abs_error, failures);
    if (failures != 0) {
        std::printf("sgemm-bench: FAIL\n");
        return 3;
    }

    // Wall clock rather than hipEvents: events are timestamped by the device,
    // and this device is a software model whose notion of time is its own.
    // What the trend is about is how long a dispatch takes to come back, which
    // is a host-side question.
    const auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < iters; ++i) {
        hipLaunchKernelGGL(sgemm, grid, block, 0, 0, da, db, dc, kM, kN, kK);
        HIP_CHECK(hipGetLastError());
    }
    HIP_CHECK(hipDeviceSynchronize());
    const auto stop = std::chrono::steady_clock::now();

    const double seconds =
        std::chrono::duration<double>(stop - start).count() / iters;
    const double flops = 2.0 * kM * kN * kK;
    std::printf("sgemm-bench: seconds_per_iter=%.9g gflops=%.9g\n", seconds,
                flops / seconds / 1e9);

    HIP_CHECK(hipFree(da));
    HIP_CHECK(hipFree(db));
    HIP_CHECK(hipFree(dc));

    std::printf("sgemm-bench: PASS\n");
    return 0;
}
