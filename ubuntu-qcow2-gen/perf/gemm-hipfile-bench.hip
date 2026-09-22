// gemm-hipfile-bench.hip
//
// Read the GEMM's operands off the emulated NVMe controller through hipFile,
// straight into GPU memory, then multiply them there. One binary, two
// numbers: GB/s for the storage path and GFLOP/s for the compute that
// consumes it, with the second validating the first.
//
// Built and run inside the guest by scripts/perf-harness.sh, after amdgpu has
// bound to the rocjitsu emulated gfx1250 over vfio-user and the emulated NVMe
// namespace has been given a filesystem.
//
// BUILD -- -O2 matters, see "no scratch" below:
//
//     hipcc -O2 --offload-arch=gfx1250 \
//         -o gemm-hipfile-bench gemm-hipfile-bench.hip -lhipfile
//
// RUN -- needs /dev/kfd (root:render) and a directory on a filesystem that
// takes O_DIRECT, which a raw block device is not:
//
//     sudo ./gemm-hipfile-bench /mnt/nvme [iters]
//
// EXIT CODES
//     0  the payload was read through hipFile and the product validated
//     1  a HIP API call failed
//     2  hipFile is unavailable, or refused the file or the buffer
//     3  the product did not match the CPU reference
//     4  the build is unsuitable -- the kernel needs scratch; see below
//
// WHY THIS EXISTS ALONGSIDE sgemm-bench.hip
//     sgemm-bench answers "does the emulated GPU compute, and how fast".
//     This answers "can bytes get from the emulated NVMe controller into that
//     GPU's memory without passing through the host, and how fast" -- and
//     then proves the bytes arrived intact by computing with them, which a
//     bandwidth benchmark on its own never does. A storage path that reads
//     the right number of bytes from the wrong offset is fast and useless,
//     and only the GEMM notices.
//
//     It also replaces what fio's libhipfile ioengine was doing here. fio
//     measures the same library well, but it needs the engine built into the
//     fio binary, and its number is bytes moved with nothing checking them.
//     This is ours, it is one file, and it fails loudly.
//
// WHY 1 MiB BLOCKS
//     O_DIRECT wants the transfer aligned to the device's logical block, and
//     hipFile is at its least surprising on large aligned chunks. 1 MiB is
//     also what ubuntu-rocm-ernic's S3-over-RDMA sweep uses for its tracked
//     object size, so the two storage numbers on the trend page are at the
//     same granularity and can be read against each other.
//
// WHY NO SCRATCH
//     On rocjitsu's emulated gfx1250 any kernel with a non-zero private
//     (scratch) segment fails -- see rocjitsu-scratch-repro.hip in
//     ubuntu-rocm-rocjitsu. The kernel below is the one from sgemm-bench.hip,
//     duplicated rather than shared for the same reason rocm-ernic duplicates
//     its token codec into tests/s3_rdma_client.c: this file is copied into a
//     guest and built there on its own. The runtime assertion on
//     hipFuncAttributes is what keeps the two from drifting silently.
//
// COMPAT MODE
//     The emulated GPU has no DMA engine behind it, so hipFileBufRegister may
//     refuse the buffer outright. HIPFILE_ALLOW_COMPAT_MODE=true lets the
//     library fall back to a bounce buffer instead, and this program sets it
//     if the caller has not: the fallback is the code path a consumer on this
//     stack actually gets, and a benchmark that declines to measure it would
//     be measuring nothing at all. Which path was taken is printed, because
//     a trend that silently changes path is a trend that lies.
//
//     Two separate fields, because they are two separate facts and only the
//     second is an observation. compat_requested is what this program asked
//     the library for; buf_registered is whether hipFileBufRegister actually
//     took the buffer. Printing the env var alone -- which an earlier version
//     did, before the driver was even open -- is a constant dressed up as a
//     measurement, and a constant cannot report a path change.
//
// STABLE OUTPUT CONTRACT
//     The harness greps these; keep the shapes if you change the wording.
//
//         gemm-hipfile-bench: device=... arch=...
//         gemm-hipfile-bench: path=... block_bytes=... blocks=... iters=...
//         gemm-hipfile-bench: compat_requested=... buf_registered=...
//         gemm-hipfile-bench: private_segment_bytes=0
//         gemm-hipfile-bench: read_bytes=... seconds_per_pass=... read_gbs=...
//         gemm-hipfile-bench: m=128 n=128 k=128
//         gemm-hipfile-bench: max_absolute_error=... failures=0
//         gemm-hipfile-bench: gemm_seconds_per_iter=... gflops=...
//         gemm-hipfile-bench: PASS

// O_DIRECT is not in POSIX, and glibc gates it on this. hipcc's clang++ front
// end defines it already through libstdc++, but only as a side effect.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <hip/hip_runtime.h>

#if __has_include(<hipfile/hipfile.h>)
#include <hipfile/hipfile.h>
#else
// nixl's AIS plugin includes it this way, with ROCm's hip include directory
// on the search path; the therock packaging puts it a directory deeper.
#include <hipfile.h>
#endif

#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// The shape sgemm-bench uses, and for the same reason: every instruction is
// interpreted, so 128^3 is already seconds per iteration.
constexpr int kM = 128;
constexpr int kN = 128;
constexpr int kK = 128;

constexpr size_t kBlock = 1u << 20;   // 1 MiB, see "why 1 MiB blocks" above
constexpr size_t kBlocks = 32;        // 32 MiB read per pass
constexpr size_t kPayload = kBlock * kBlocks;

constexpr size_t kABytes = static_cast<size_t>(kM) * kK * sizeof(float);
constexpr size_t kBBytes = static_cast<size_t>(kK) * kN * sizeof(float);
constexpr size_t kBOffset = kABytes;

constexpr float kTolerance = 1e-3f;

#define HIP_CHECK(expr)                                                       \
    do {                                                                      \
        hipError_t err_ = (expr);                                             \
        if (err_ != hipSuccess) {                                             \
            std::fprintf(stderr, "gemm-hipfile-bench: %s failed: %s\n",       \
                         #expr, hipGetErrorString(err_));                     \
            return 1;                                                         \
        }                                                                     \
    } while (0)

#define HIPFILE_CHECK(expr)                                                   \
    do {                                                                      \
        hipFileError_t s_ = (expr);                                           \
        if (s_.err != hipFileSuccess) {                                       \
            std::fprintf(stderr,                                              \
                         "gemm-hipfile-bench: %s failed: err=%d drv=%d\n",    \
                         #expr, (int)s_.err, (int)s_.hip_drv_err);            \
            return 2;                                                         \
        }                                                                     \
    } while (0)

// Identical to sgemm-bench.hip's kernel. One output element per thread,
// accumulated in a register, no __shared__ tiling and no local arrays, so at
// -O2 the private segment comes out at zero.
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

// Deterministic, and deliberately not random: a trend that moves because the
// data moved is not a trend. Same generators as sgemm-bench.hip, so a
// regression that shows up in one and not the other is about the path, not
// about the arithmetic.
static void fill_operands(std::vector<float>& ha, std::vector<float>& hb) {
    ha.resize(static_cast<size_t>(kM) * kK);
    hb.resize(static_cast<size_t>(kK) * kN);
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
}

// Lay the two operands down at the head of the payload and fill the rest with
// a byte pattern. The tail is never read back for correctness -- it is there
// so the timed pass moves enough bytes to time -- but it is written from a
// generator rather than left as a hole so the file is fully allocated and the
// read is not measuring a sparse-file shortcut.
static bool write_payload(const std::string& path, const std::vector<float>& ha,
                          const std::vector<float>& hb) {
    const int fd = ::open(path.c_str(), O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) {
        std::fprintf(stderr, "gemm-hipfile-bench: open %s: %s\n", path.c_str(),
                     std::strerror(errno));
        return false;
    }

    std::vector<unsigned char> block(kBlock);
    bool ok = true;
    for (size_t b = 0; ok && b < kBlocks; ++b) {
        for (size_t i = 0; i < kBlock; ++i) {
            block[i] = static_cast<unsigned char>((b * 31 + i * 7) & 0xff);
        }
        if (b == 0) {
            std::memcpy(block.data(), ha.data(), kABytes);
            std::memcpy(block.data() + kBOffset, hb.data(), kBBytes);
        }
        size_t done = 0;
        while (done < kBlock) {
            const ssize_t n = ::write(fd, block.data() + done, kBlock - done);
            if (n <= 0) {
                std::fprintf(stderr, "gemm-hipfile-bench: write: %s\n",
                             std::strerror(errno));
                ok = false;
                break;
            }
            done += static_cast<size_t>(n);
        }
    }

    // Durability is not the point; getting the bytes off the page cache and
    // onto the emulated namespace is, so the O_DIRECT read below has
    // something to fetch.
    if (ok && ::fsync(fd) != 0) {
        std::fprintf(stderr, "gemm-hipfile-bench: fsync: %s\n",
                     std::strerror(errno));
        ok = false;
    }
    ::close(fd);
    return ok;
}

int main(int argc, char** argv) {
    std::string dir = "/mnt/nvme";
    int iters = 4;
    if (argc > 1) {
        dir = argv[1];
    }
    if (argc > 2) {
        iters = std::atoi(argv[2]);
        if (iters < 1) {
            std::fprintf(stderr, "gemm-hipfile-bench: iters must be >= 1\n");
            return 1;
        }
    }
    const std::string path = dir + "/gemm-hipfile-bench.bin";

    // Set before hipFileDriverOpen, which is where the library decides. See
    // "compat mode" above for why the fallback is wanted rather than tolerated.
    const bool compat_from_caller = ::getenv("HIPFILE_ALLOW_COMPAT_MODE") != nullptr;
    if (!compat_from_caller) {
        ::setenv("HIPFILE_ALLOW_COMPAT_MODE", "true", 0);
    }

    hipDeviceProp_t prop{};
    HIP_CHECK(hipGetDeviceProperties(&prop, 0));
    std::printf("gemm-hipfile-bench: device=%s arch=%s\n", prop.name,
                prop.gcnArchName);
    std::printf("gemm-hipfile-bench: path=%s block_bytes=%zu blocks=%zu "
                "iters=%d\n",
                path.c_str(), kBlock, kBlocks, iters);

    std::vector<float> ha, hb;
    fill_operands(ha, hb);
    if (!write_payload(path, ha, hb)) {
        return 2;
    }

    // The scratch assertion, before anything is timed and before any device
    // memory is committed. A non-zero private segment means the build is
    // unsuitable and the kernel would either hang or leave the output
    // untouched, which is a far more confusing failure than this message.
    hipFuncAttributes attr{};
    HIP_CHECK(hipFuncGetAttributes(&attr, reinterpret_cast<const void*>(sgemm)));
    std::printf("gemm-hipfile-bench: private_segment_bytes=%zu\n",
                static_cast<size_t>(attr.localSizeBytes));
    if (attr.localSizeBytes != 0) {
        std::fprintf(stderr,
                     "gemm-hipfile-bench: kernel needs %zu bytes of scratch; "
                     "rocjitsu's emulated gfx1250 cannot run it. Rebuild with "
                     "-O2.\n",
                     static_cast<size_t>(attr.localSizeBytes));
        return 4;
    }

    HIPFILE_CHECK(hipFileDriverOpen());

    // O_DIRECT is the whole point: without it the read is served from the
    // guest's page cache and the number says nothing about the emulated
    // controller. hipFile refuses a handle on a file opened without it.
    const int fd = ::open(path.c_str(), O_RDONLY | O_DIRECT);
    if (fd < 0) {
        std::fprintf(stderr,
                     "gemm-hipfile-bench: open %s O_DIRECT: %s\n"
                     "  hipFile needs a filesystem path that takes O_DIRECT, "
                     "not a raw block device.\n",
                     path.c_str(), std::strerror(errno));
        hipFileDriverClose();
        return 2;
    }

    hipFileHandle_t fh{};
    hipFileDescr_t descr{};
    descr.handle.fd = fd;
    descr.type = hipFileHandleTypeOpaqueFD;
    HIPFILE_CHECK(hipFileHandleRegister(&fh, &descr));

    void* dev = nullptr;
    HIP_CHECK(hipMalloc(&dev, kPayload));

    // Deliberately not fatal. A refused registration is a slower path, not a
    // broken one -- hipFileRead still works against an unregistered buffer --
    // and on this stack it is the difference the trend most wants to see. Fail
    // here and the run reports nothing at all about the day it started
    // happening.
    const hipFileError_t reg = hipFileBufRegister(dev, kPayload, 0);
    const bool buf_registered = reg.err == hipFileSuccess;
    if (!buf_registered) {
        std::fprintf(stderr,
                     "gemm-hipfile-bench: hipFileBufRegister refused the "
                     "buffer (err=%d drv=%d); reading unregistered\n",
                     static_cast<int>(reg.err), static_cast<int>(reg.hip_drv_err));
    }
    std::printf("gemm-hipfile-bench: compat_requested=%s buf_registered=%s\n",
                compat_from_caller ? "caller" : "self",
                buf_registered ? "yes" : "no");

    // One untimed pass first. The first read pays for the library's lazy
    // setup and for the emulated namespace's first touch of every block,
    // neither of which is what the trend is about.
    for (size_t b = 0; b < kBlocks; ++b) {
        const ssize_t n = hipFileRead(fh, dev, kBlock,
                                      static_cast<off_t>(b * kBlock),
                                      static_cast<off_t>(b * kBlock));
        if (n != static_cast<ssize_t>(kBlock)) {
            std::fprintf(stderr,
                         "gemm-hipfile-bench: warm hipFileRead block %zu "
                         "returned %zd of %zu: %s\n",
                         b, n, kBlock, std::strerror(errno));
            return 2;
        }
    }

    const auto read_start = std::chrono::steady_clock::now();
    for (int it = 0; it < iters; ++it) {
        for (size_t b = 0; b < kBlocks; ++b) {
            const ssize_t n = hipFileRead(fh, dev, kBlock,
                                          static_cast<off_t>(b * kBlock),
                                          static_cast<off_t>(b * kBlock));
            if (n != static_cast<ssize_t>(kBlock)) {
                std::fprintf(stderr,
                             "gemm-hipfile-bench: hipFileRead block %zu "
                             "returned %zd of %zu: %s\n",
                             b, n, kBlock, std::strerror(errno));
                return 2;
            }
        }
    }
    const auto read_stop = std::chrono::steady_clock::now();

    const double read_seconds =
        std::chrono::duration<double>(read_stop - read_start).count() / iters;
    // GB/s decimal, as drives are sold and as the fio leg reports it.
    std::printf("gemm-hipfile-bench: read_bytes=%zu seconds_per_pass=%.9g "
                "read_gbs=%.9g\n",
                kPayload, read_seconds,
                static_cast<double>(kPayload) / read_seconds / 1e9);

    // The operands are now in device memory because the storage path put them
    // there -- nothing was copied from the host. If the read landed at the
    // wrong offset or short, the product below is what notices.
    float* const da = static_cast<float*>(dev);
    float* const db = reinterpret_cast<float*>(static_cast<char*>(dev) + kBOffset);
    float* dc = nullptr;
    HIP_CHECK(hipMalloc(&dc, static_cast<size_t>(kM) * kN * sizeof(float)));

    const dim3 block(16, 16);
    const dim3 grid((kN + block.x - 1) / block.x, (kM + block.y - 1) / block.y);
    std::printf("gemm-hipfile-bench: m=%d n=%d k=%d\n", kM, kN, kK);

    // Warm-up and validation in one pass, so the timed loop is never the
    // first dispatch: that one pays for code-object load and queue setup,
    // which on this device is minutes rather than microseconds.
    hipLaunchKernelGGL(sgemm, grid, block, 0, 0, da, db, dc, kM, kN, kK);
    HIP_CHECK(hipGetLastError());
    HIP_CHECK(hipDeviceSynchronize());

    std::vector<float> hc(static_cast<size_t>(kM) * kN, 0.0f);
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
    std::printf("gemm-hipfile-bench: max_absolute_error=%.6g failures=%ld\n",
                max_abs_error, failures);
    if (failures != 0) {
        std::printf("gemm-hipfile-bench: FAIL\n");
        std::fprintf(stderr,
                     "gemm-hipfile-bench: the product of the operands hipFile "
                     "read does not match the CPU reference, so the bytes that "
                     "arrived are not the bytes on disk.\n");
        return 3;
    }

    const auto gemm_start = std::chrono::steady_clock::now();
    for (int i = 0; i < iters; ++i) {
        hipLaunchKernelGGL(sgemm, grid, block, 0, 0, da, db, dc, kM, kN, kK);
        HIP_CHECK(hipGetLastError());
    }
    HIP_CHECK(hipDeviceSynchronize());
    const auto gemm_stop = std::chrono::steady_clock::now();

    const double gemm_seconds =
        std::chrono::duration<double>(gemm_stop - gemm_start).count() / iters;
    const double flops = 2.0 * kM * kN * kK;
    std::printf("gemm-hipfile-bench: gemm_seconds_per_iter=%.9g gflops=%.9g\n",
                gemm_seconds, flops / gemm_seconds / 1e9);

    HIP_CHECK(hipFree(dc));
    if (buf_registered) {
        hipFileBufDeregister(dev);
    }
    HIP_CHECK(hipFree(dev));
    hipFileHandleDeregister(fh);
    ::close(fd);
    hipFileDriverClose();
    ::unlink(path.c_str());

    std::printf("gemm-hipfile-bench: PASS\n");
    return 0;
}
