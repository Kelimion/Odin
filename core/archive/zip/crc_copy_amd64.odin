#+build amd64
package archive_zip

import "base:intrinsics"
import "core:hash"
import "core:simd/x86"
import "core:sys/info"

@(private = "file")
CRC_COPY_STATIC :: intrinsics.has_target_feature("pclmul") && intrinsics.has_target_feature("sse4.1") && intrinsics.has_target_feature("avx2") && intrinsics.has_target_feature("vpclmulqdq")

@(private = "file")
CRC_COPY_MIN :: 256

@(private = "file")
_crc_copy_wide := CRC_COPY_STATIC

@(init, private = "file")
_detect_crc_copy :: proc "contextless" () {
	features := info.cpu_features()
	if .pclmulqdq not_in features || .sse41 not_in features || .avx2 not_in features {
		return
	}
	max_id, _, _, _ := intrinsics.x86_cpuid(0, 0)
	if max_id < 7 {
		return
	}
	_, _, ecx7, _ := intrinsics.x86_cpuid(7, 0)
	_crc_copy_wide = ecx7 >> 10 & 1 != 0
}

@(private)
_crc32_copy :: proc "contextless" (dst, src: []u8, seed: u32) -> u32 {
	n := len(src)
	if n >= CRC_COPY_MIN && (CRC_COPY_STATIC || _crc_copy_wide) {
		state, p := _crc32_copy_256(raw_data(dst), raw_data(src), n, ~seed)
		copy(dst[p:n], src[p:n])
		return hash.crc32(src[p:n], ~state)
	}
	copy(dst[:n], src)
	return hash.crc32(src, seed)
}

@(private = "file", enable_target_feature = "sse2,sse4.1,pclmul,avx,avx2,vpclmulqdq")
_crc32_copy_256 :: proc "contextless" (dst, src: [^]u8, length: int, crc: u32) -> (state: u32, consumed: int) #no_bounds_check {
	K1024  :: x86.__m256i{0x1e88ef372, 0x14a7fe880, 0x1e88ef372, 0x14a7fe880}
	K256   :: x86.__m256i{0x0f1da05aa, 0x15a546366, 0x0f1da05aa, 0x15a546366}
	K34    :: x86.__m128i{0x1751997d0, 0x0ccaa009e}
	K5     :: x86.__m128i{0x163cd6124, 0}
	KP     :: x86.__m128i{0x1db710641, 0x1f7011641}
	MASK32 :: x86.__m128i{0xffffffff, 0}

	@(enable_target_feature = "avx,avx2,vpclmulqdq")
	fold :: #force_inline proc "contextless" (x, k: x86.__m256i) -> x86.__m256i {
		return x86._mm256_xor_si256(x86._mm256_clmulepi64_epi128(x, k, 0x00), x86._mm256_clmulepi64_epi128(x, k, 0x11))
	}
	@(enable_target_feature = "avx")
	load :: #force_inline proc "contextless" (p: [^]u8) -> x86.__m256i {
		return x86._mm256_loadu_si256((^x86.__m256i)(p))
	}
	@(enable_target_feature = "avx")
	store :: #force_inline proc "contextless" (p: [^]u8, v: x86.__m256i) {
		x86._mm256_storeu_si256((^x86.__m256i)(p), v)
	}

	v0 := load(src[0:])
	v1 := load(src[32:])
	v2 := load(src[64:])
	v3 := load(src[96:])
	store(dst[0:], v0)
	store(dst[32:], v1)
	store(dst[64:], v2)
	store(dst[96:], v3)
	y0 := x86._mm256_xor_si256(v0, x86.__m256i{i64(crc), 0, 0, 0})
	y1 := v1
	y2 := v2
	y3 := v3
	p  := 128

	for length - p >= 128 {
		v0 = load(src[p:])
		v1 = load(src[p + 32:])
		v2 = load(src[p + 64:])
		v3 = load(src[p + 96:])
		store(dst[p:], v0)
		store(dst[p + 32:], v1)
		store(dst[p + 64:], v2)
		store(dst[p + 96:], v3)
		y0 = x86._mm256_xor_si256(fold(y0, K1024), v0)
		y1 = x86._mm256_xor_si256(fold(y1, K1024), v1)
		y2 = x86._mm256_xor_si256(fold(y2, K1024), v2)
		y3 = x86._mm256_xor_si256(fold(y3, K1024), v3)
		p += 128
	}

	y0 = x86._mm256_xor_si256(fold(y0, K256), y1)
	y0 = x86._mm256_xor_si256(fold(y0, K256), y2)
	y0 = x86._mm256_xor_si256(fold(y0, K256), y3)

	x0 := x86._mm256_castsi256_si128(y0)
	x0  = x86._mm_xor_si128(x86._mm_clmulepi64_si128(x0, K34, 0x00), x86._mm_clmulepi64_si128(x0, K34, 0x11))
	x0  = x86._mm_xor_si128(x0, x86._mm256_extracti128_si256(y0, 1))

	v := x86._mm_xor_si128(x86._mm_clmulepi64_si128(x0, K34, 0x10), x86._mm_srli_si128(x0, 8))
	v  = x86._mm_xor_si128(x86._mm_clmulepi64_si128(x86._mm_and_si128(v, MASK32), K5, 0x00), x86._mm_srli_si128(v, 4))
	t := x86._mm_clmulepi64_si128(x86._mm_and_si128(v, MASK32), KP, 0x10)
	t  = x86._mm_clmulepi64_si128(x86._mm_and_si128(t, MASK32), KP, 0x00)
	v  = x86._mm_xor_si128(v, t)
	return u32(x86._mm_extract_epi32(v, 1)), p
}
