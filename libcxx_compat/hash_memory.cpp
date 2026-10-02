// std::__hash_memory for Android 16+ vendor binaries (citadeld). Newer libc++
// moved its memory hash out of the headers into this exported function; our
// recovery's Android 14 libc++.so doesn't export it. Ours is the SAME algorithm:
// it calls the header-only __murmur2_or_cityhash<size_t> (CityHash64) that this
// libc++'s headers use inline - exactly what newer libc++'s __hash_memory wraps.
#include <cstddef>
#include <functional>

_LIBCPP_BEGIN_NAMESPACE_STD

_LIBCPP_EXPORTED_FROM_ABI size_t __hash_memory(const void* __ptr, size_t __size) _NOEXCEPT {
    return __murmur2_or_cityhash<size_t>()(__ptr, __size);
}

_LIBCPP_END_NAMESPACE_STD
