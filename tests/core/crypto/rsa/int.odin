// Tests for the constant time RSA primitives
package test_core_crypto_rsa

import    "base:runtime"
import ct "core:crypto/_rsa"
import    "core:log"
import    "core:slice"
import    "core:testing"

@(test)
is_zero :: proc(t: ^testing.T) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	arr := make_rand([5]u32, N)

	for &v in arr {
		v[0] = ct.i31_bit_length(v[1:])
		sum: u64
		for w in v[1:] {
			sum += u64(w)
		}
		testing.expect_value(t, ct.i31_is_zero(v[:]), 1 if sum == 0 else 0)

		for &w in v[1:] {
			w = 0
		}
		testing.expect_value(t, ct.i31_is_zero(v[:]), 1)
	}
}

@(test)
i31_add :: proc(t: ^testing.T) {
	N :: 5
	res: [N]u32

	for v in i31_add_test_vectors {
		if len(v.a) > N || len(v.b) > N || len(v.res) > N {
			log.infof("Skipped %v, not enough scratch space", v)
			continue
		}
		if !(len(v.a) == len(v.b) && len(v.b) == len(v.res)) {
			log.infof("Skipped %v, expected `a`, `b` and `res` lengths to be equal", v)
			continue
		}

		// Copy into writable memory
		copy(res[:], v.a[:])

		// Add b to "a" in place
		cc := ct.i31_add(res[:], v.b[:], 1)

		testing.expect(t, slice.equal(res[:], v.res))
		testing.expect_value(t, cc, v.carry)
	}
}

@(test)
i31_sub :: proc(t: ^testing.T) {
	N :: 5
	res: [N]u32

	for v in i31_sub_test_vectors {
		if len(v.a) > N || len(v.b) > N || len(v.res) > N {
			log.infof("Skipped %v, not enough scratch space", v)
			continue
		}
		if !(len(v.a) == len(v.b) && len(v.b) == len(v.res)) {
			log.infof("Skipped %v, expected `a`, `b` and `res` lengths to be equal", v)
			continue
		}

		// Copy into writable memory
		copy(res[:], v.a[:])

		// Add b to "a" in place
		cc := ct.i31_sub(res[:], v.b[:], 1)

		testing.expect(t, slice.equal(res[:], v.res))
		testing.expect_value(t, cc, v.carry)
	}
}

@(test)
i31_bit_length :: proc (t: ^testing.T) {
	for v in i31_add_test_vectors {
		a_len := ct.i31_bit_length(v.a[1:])
		b_len := ct.i31_bit_length(v.b[1:])

		testing.expect_value(t, a_len, v.a[0])
		testing.expect_value(t, b_len, v.b[0])
	}
}