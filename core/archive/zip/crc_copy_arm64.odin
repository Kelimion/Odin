#+build arm64
package archive_zip

import "base:intrinsics"
import "core:hash"
import "core:simd/arm"

@(private = "file")
CRC_COPY_STATIC :: ODIN_OS == .Darwin || (intrinsics.has_target_feature("crc") && intrinsics.has_target_feature("aes"))

@(private = "file")
CRC_COPY_MIN :: 192

@(private)
_crc32_copy :: proc "contextless" (dst, src: []u8, seed: u32) -> u32 {
	n := len(src)
	when CRC_COPY_STATIC {
		if n >= CRC_COPY_MIN {
			state, p := _crc32_copy_128(raw_data(dst), raw_data(src), n, ~seed)
			copy(dst[p:n], src[p:n])
			return hash.crc32(src[p:n], ~state)
		}
	}
	copy(dst[:n], src)
	return hash.crc32(src, seed)
}

@(private = "file", enable_target_feature = "neon,aes,crc")
_crc32_copy_128 :: proc "contextless" (dst, src: [^]u8, length: int, crc: u32) -> (state: u32, consumed: int) #no_bounds_check {
	K12 :: arm.uint64x2_t{0x154442bd4, 0x1c6e41596}
	K34 :: arm.uint64x2_t{0x1751997d0, 0x0ccaa009e}

	@(enable_target_feature = "neon,aes")
	fold :: #force_inline proc "contextless" (x, k: arm.uint64x2_t) -> arm.uint64x2_t {
		lo := arm.vmull_p64(arm.vgetq_lane_u64(x, 0), arm.vgetq_lane_u64(k, 0))
		hi := arm.vmull_p64(arm.vgetq_lane_u64(x, 1), arm.vgetq_lane_u64(k, 1))
		return transmute(arm.uint64x2_t)(lo ~ hi)
	}
	@(enable_target_feature = "neon")
	load :: #force_inline proc "contextless" (p: [^]u8) -> arm.uint64x2_t {
		return intrinsics.unaligned_load((^arm.uint64x2_t)(p))
	}
	@(enable_target_feature = "neon")
	store :: #force_inline proc "contextless" (p: [^]u8, v: arm.uint64x2_t) {
		intrinsics.unaligned_store((^arm.uint64x2_t)(p), v)
	}

	v0 := load(src[0:])
	v1 := load(src[16:])
	v2 := load(src[32:])
	v3 := load(src[48:])
	store(dst[0:], v0)
	store(dst[16:], v1)
	store(dst[32:], v2)
	store(dst[48:], v3)
	x0 := v0 ~ arm.uint64x2_t{u64(crc), 0}
	x1 := v1
	x2 := v2
	x3 := v3
	p  := 64

	for length - p >= 64 {
		v0 = load(src[p:])
		v1 = load(src[p + 16:])
		v2 = load(src[p + 32:])
		v3 = load(src[p + 48:])
		store(dst[p:], v0)
		store(dst[p + 16:], v1)
		store(dst[p + 32:], v2)
		store(dst[p + 48:], v3)
		x0 = fold(x0, K12) ~ v0
		x1 = fold(x1, K12) ~ v1
		x2 = fold(x2, K12) ~ v2
		x3 = fold(x3, K12) ~ v3
		p += 64
	}

	x0 = fold(x0, K34) ~ x1
	x0 = fold(x0, K34) ~ x2
	x0 = fold(x0, K34) ~ x3

	c := arm.__crc32d(0, arm.vgetq_lane_u64(x0, 0))
	c  = arm.__crc32d(c, arm.vgetq_lane_u64(x0, 1))
	return c, p
}
