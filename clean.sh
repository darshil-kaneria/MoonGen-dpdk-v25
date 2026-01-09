#!/bin/bash

cd $(dirname "${BASH_SOURCE[0]}")

(
cd libmoon
rm -rf build CMakeCache.txt CMakeFiles Makefile cmake_install.cmake
rm -rf deps/dpdk/arm64-native-linux-gcc
rm -rf deps/dpdk/x86_64-native-linux-gcc
(cd deps/luajit && make clean 2>/dev/null)
(cd deps/dpdk-kmods/linux/igb_uio && make clean 2>/dev/null)
(cd lua/lib/turbo && make clean 2>/dev/null)
)

rm -rf build CMakeCache.txt CMakeFiles Makefile cmake_install.cmake
mkdir -p build
