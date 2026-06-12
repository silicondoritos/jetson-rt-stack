FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV CROSS_COMPILE=/opt/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
ENV ARCH=arm64

# Install build dependencies.
# fakeroot + debhelper are required for `make bindeb-pkg` (the step that
# produces linux-headers-*-tegra_*.deb for on-target DKMS).
# Without them the kernel build still produces Image + .ko's but the
# headers .deb step fails and downstream installers (ZED SDK, etc.)
# can't rebuild against the running kernel.
RUN apt-get update && apt-get install -y \
    build-essential bc flex bison libssl-dev zstd git \
    openssl xxd dpkg-dev dh-make fakeroot debhelper rsync qemu-user-static \
    wget bzip2 sudo tzdata python3 python3-pip kmod device-tree-compiler && \
    rm -rf /var/lib/apt/lists/* && \
    pip3 install --no-cache-dir kconfiglib

# Download and extract Bootlin Toolchain.
# NOTE: the Bootlin toolchain sits at the release-INDEPENDENT r36_release_v3.0/
# mirror. BSP/rootfs/sources move per release (R36.4.3 -> r36_release_v4.3/), but
# this toolchain path does not: v4.3/toolchain/ and the earlier "v5.0" URL both
# 404 -- only v3.0/toolchain/ resolves. Verified June 2026.
# https://developer.nvidia.com/embedded/jetson-linux-r3643
WORKDIR /opt
RUN wget -q https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2 && \
    tar xjf aarch64--glibc--stable-2022.08-1.tar.bz2 && \
    rm aarch64--glibc--stable-2022.08-1.tar.bz2

# Create user with sudo privileges and allow ALL to use sudo without password
RUN useradd -m -s /bin/bash j && \
    echo "ALL ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER j
WORKDIR /home/j/dev/custom_kernel
