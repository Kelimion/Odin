/*
	Constant time primitives for RSA

	Ported from [BearSSL](https://www.bearssl.org) by Thomas Pornin <pornin@bolet.org>.
	Used with permission.
*/
package _rsa_int

/*
	TODO(Jeroen): Check that the following are applied as necessary:
	- @(optimization_mode="none")
	- "contextless"
	- #no_bounds_check
	- #force_inline
*/

/*
 * Integers 'i31'
 * --------------
 *
 * The 'i31' functions implement computations on big integers using
 * an internal representation as an array of 32-bit integers. For
 * an array x[]:
 *  -- x[0] encodes the array length and the "announced bit length"
 *     of the integer: namely, if the announced bit length is k,
 *     then x[0] = ((k / 31) << 5) + (k % 31).
 *  -- x[1], x[2]... contain the value in little-endian order, 31
 *     bits per word (x[1] contains the least significant 31 bits).
 *     The upper bit of each word is 0.
 *
 * Multiplications rely on the elementary 32x32->64 multiplication.
 *
 * The announced bit length specifies the number of bits that are
 * significant in the subsequent 32-bit words. Unused bits in the
 * last (most significant) word are set to 0; subsequent words are
 * uninitialized and need not exist at all.
 *
 * The execution time and memory access patterns of all computations
 * depend on the announced bit length, but not on the actual word
 * values. For modular integers, the announced bit length of any integer
 * modulo n is equal to the actual bit length of n; thus, computations
 * on modular integers are "constant-time" (only the modulus length may
 * leak).
 */

I31_MASK    :: 0x7fff_ffff
I62_MASK    :: 0x3fff_ffff_ffff_ffff
I31_LO_MASK :: 0xffff
I31_HI_MASK :: 0x8000_0000

// Test whether an integer `x: []u32` is zero.
@(optimization_mode="none")
i31_is_zero :: proc "contextless" (x: []u32) -> (res: u32) #no_bounds_check {
	z: u32

	for u := (x[0] + 31) >> 5; u > 0; u -= 1 {
		z |= x[u]
	}
	return ~(z | -z) >> 31
}

/*
	Add `b: []u32` to `a: []u32` if `ctl` is `1`.
	If `0`, `a` is left alone but the `carry` will still be computed.
*/
@(optimization_mode="none")
i31_add :: proc (a: []u32, b: []u32, ctl: u32) -> (carry: u32) #no_bounds_check {
	words := uint(a[0] + 63) >> 5
	for u in uint(1)..<words {
		aw   := a[u]
		bw   := b[u]
		naw  := aw + bw + carry
		carry = naw >> 31
		a[u] = mux(ctl, naw & I31_MASK, aw)
	}
	return
}

/*
	Subtract `b: []u32` from `a: []u32` and return the carry (`0` or `1`).
	If `ctl` is `0`, then `a` is unmodified, but the carry is still computed
	and returned.

	The slices `a` and `b` MUST have the same announced bit length (in subscript `0`)

	`a` and `b` MAY be the same array, but partial overlap is not allowed.
*/
@(optimization_mode="none")
i31_sub :: proc (a: []u32, b: []u32, ctl: u32) -> (carry: u32) #no_bounds_check {
	words := uint(a[0] + 63) >> 5
	for u in uint(1)..<words {
		aw   := a[u]
		bw   := b[u]
		naw  := aw - bw - carry
		carry = naw >> 31
		a[u] = mux(ctl, naw & I31_MASK, aw)
	}
	return
}

/*
	Compute the ENCODED actual bit length of an integer `x: []u32`.
	The argument `x` should point to the first (least significant)
	value word of the integer.

	The upper bit of each value word MUST be `0`.

	Returned value is `((k / 31) << 5) + (k % 31)` if the bit length is `k`.

	CT: value or length of `x` does not leak.
*/
@(optimization_mode="none")
i31_bit_length :: proc "contextless" (x: []u32) -> (res: u32) #no_bounds_check {
	tw, twk: u32

	xlen := len(x)
	for xlen > 0 {
		xlen -= 1
		c := eq(tw, 0)
		w := x[xlen]

		tw   = mux(c, w, tw)
		twk  = mux(c, u32(xlen), twk)
	}
	return (twk << 5) + bit_length(tw)
}