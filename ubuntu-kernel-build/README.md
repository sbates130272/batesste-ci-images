# ubuntu-kernel-build

Docker image for building Linux kernels and out-of-tree (OOT) kernel modules.

## Overview

This image provides a complete environment for:
- Building Linux kernels from source
- Building out-of-tree kernel modules
- Cross-compilation support (can be extended)

## Base Image

- Ubuntu 24.04

## Installed Packages

### Kernel Build Tools
- `build-essential` - GCC, make, and other essential build tools
- `git` - Version control
- `libncurses-dev` - Required for kernel menuconfig
- `libssl-dev` - SSL/TLS library development files
- `libelf-dev` - ELF library development files
- `bc` - Arbitrary precision calculator (required by kernel build)
- `bison` - Parser generator
- `flex` - Fast lexical analyzer
- `dwarves` - Debugging information manipulation tools
- `rsync` - Efficient file synchronization
- `kmod` - Kernel module management utilities
- `cpio` - Archive utility

### Kernel Headers
- `linux-headers-generic` - Kernel headers for building out-of-tree modules

## Usage

### Building the Image

```bash
docker build -f ubuntu-kernel-build/Dockerfile \
  -t batesste-ci-images-ubuntu-kernel-build:latest \
  ubuntu-kernel-build
```

Or use the build script:

```bash
./build-and-push.sh ubuntu-kernel-build
```

### Building a Kernel

```bash
docker run --rm -it \
  -v $(pwd)/kernel-source:/build/kernel \
  -v $(pwd)/output:/output \
  batesste-ci-images-ubuntu-kernel-build:latest \
  bash -c "cd /build/kernel && make defconfig && make -j$(nproc)"
```

### Building an Out-of-Tree Kernel Module

```bash
docker run --rm -it \
  -v $(pwd)/module-source:/build/module \
  -v $(pwd)/output:/output \
  batesste-ci-images-ubuntu-kernel-build:latest \
  bash -c "cd /build/module && make -C /lib/modules/$(uname -r)/build M=$(pwd) modules"
```

### Using Kernel Headers

The image includes kernel headers, so you can build modules against the
host kernel version:

```bash
docker run --rm -it \
  -v $(pwd)/module-source:/build/module \
  batesste-ci-images-ubuntu-kernel-build:latest \
  bash -c "cd /build/module && make -C /usr/src/linux-headers-$(uname -r) M=$(pwd) modules"
```

## Output

Built artifacts should be placed in `/output` which is mounted as a volume
or copied from the container.

## Notes

- The image uses Ubuntu 24.04 as the base
- Kernel headers are installed for building out-of-tree modules
- For cross-compilation, additional packages may be needed
- The working directory is `/build`
- Output directory is `/output`

