cmake_minimum_required(VERSION 2.8)
project(MoonGen C CXX)

#Options are defined in libmoon/CMakeLists.txt

set(CMAKE_CXX_FLAGS "-fno-stack-protector -Wall -Wextra -Wno-unused-parameter -g -O3 -std=gnu++11 -march=native -msse4.2")
set(CMAKE_C_FLAGS "-fno-stack-protector -Wall -Wextra -Wno-unused-parameter -g -O3 -std=gnu11 -march=native -msse4.2")
set(CMAKE_EXE_LINKER_FLAGS "-rdynamic")

set(LIBMOON_BUILD_LIBRARY true)
add_definitions(-DLIBMOON_LUA_MAIN_MODULE="moongen-main")
add_subdirectory(libmoon)

# add tbb
set(TBB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/libmoon/deps/tbb/cmake/)
find_package(TBB REQUIRED tbb)

include_directories(
	${CMAKE_CURRENT_SOURCE_DIR}/src
	${CMAKE_CURRENT_SOURCE_DIR}/lib
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/deps/dpdk/x86_64-native-linux-gcc/include
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/deps/dpdk/lib/librte_ethdev
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/deps/luajit/src
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/deps/highwayhash/highwayhash
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/deps/tbb/include
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/lib
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/src
)

set(files
	src/moongen-main
	src/software-timestamping
	src/crc-rate-limiter
	src/software-rate-limiter
	src/moonsniff
	src/histogram
	src/hashmap
)

set(libraries
	-Wl,--whole-archive moon
	${TBB_IMPORTED_TARGETS}
	-Wl,--start-group ${dpdk_STATIC_LINK_LIBRARIES} ${dpdk_STATIC_LDFLAGS} ${dpdk_STATIC_LDFLAGS_OTHER} -Wl,--end-group
)

link_directories(
	${dpdk_STATIC_LINK_DIRS}
	${CMAKE_CURRENT_BINARY_DIR}/libmoon
	${CMAKE_CURRENT_BINARY_DIR}/tbb_cmake_build/tbb_cmake_build_subdir_release
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/deps/dpdk/x86_64-native-linux-gcc/lib
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/deps/luajit/usr/local/lib
	${CMAKE_CURRENT_SOURCE_DIR}/libmoon/deps/highwayhash/lib
)

add_executable(MoonGen ${files})
target_link_libraries(MoonGen ${libraries})

