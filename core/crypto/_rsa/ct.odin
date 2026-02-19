package _rsa_int

/* ====================================================================
 *
 * Constant-time primitives. These functions manipulate 32-bit values in
 * order to provide constant-time comparisons and multiplexers.
 *
 * Boolean values (the "ctl" bits) MUST have value 0 or 1.
 *
 * Implementation notes:
 * =====================
 *
 * The uintN_t types are unsigned and with width exactly N bits; the C
 * standard guarantees that computations are performed modulo 2^N, and
 * there can be no overflow. Negation (unary '-') works on unsigned types
 * as well.
 *
 * The intN_t types are guaranteed to have width exactly N bits, with no
 * padding bit, and using two's complement representation. Casting
 * intN_t to uintN_t really is conversion modulo 2^N. Beware that intN_t
 * types, being signed, trigger implementation-defined behaviour on
 * overflow (including raising some signal): with GCC, while modular
 * arithmetics are usually applied, the optimizer may assume that
 * overflows don't occur (unless the -fwrapv command-line option is
 * added); Clang has the additional -ftrapv option to explicitly trap on
 * integer overflow or underflow.
 */

/*
/*
 * Conditional copy: src[] is copied into dst[] if and only if ctl is 1.
 * dst[] and src[] may overlap completely (but not partially).
 */
void br_ccopy(uint32_t ctl, void *dst, const void *src, size_t len);
#define CCOPY   br_ccopy
*/

import "core:crypto"

when crypto.CT_SW_MUL {
	mul31    :: sw_mul31
	mul31_lo :: sw_mul31_lo
} else {
	mul31    :: hw_mul31
	mul31_lo :: hw_mul31_lo
}

// Negate a boolean
not :: #force_inline proc "contextless" (ctl: u32) -> (res: u32) {
	return ctl ~ 1
}

// Multiplexer: returns `x` if ctl == `true`, `y` if ctl == `false`.
mux :: #force_inline proc "contextless" (ctl: u32, x, y: u32) -> (res: u32) {
	mask := -ctl
	return y ~ (mask & (x ~ y))
}

// Equality check: returns 1 if x == y, 0 otherwise.
eq :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	q := x ~ y
	return not((q | -q) >> 31)
}

// Inequality check: returns 1 if x != y, 0 otherwise.
neq :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	q := x ~ y
	return (q | -q) >> 31
}

// Comparison: returns 1 if x > y, 0 otherwise.
gt :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	/*
	 * If both x < 2^31 and y < 2^31, then y-x will have its high
	 * bit set if x > y, cleared otherwise.
	 *
	 * If either x >= 2^31 or y >= 2^31 (but not both), then the
	 * result is the high bit of x.
	 *
	 * If both x >= 2^31 and y >= 2^31, then we can virtually
	 * subtract 2^31 from both, and we are back to the first case.
	 * Since (y-2^31)-(x-2^31) = y-x, the subtraction is already
	 * fine.
	 */
	z := y - x
	return (z ~ ((x ~ y) & (x ~ z))) >> 31
}

ge :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	return not(gt(y, x))
}

lt :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	return gt(y, x)
}

le :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	return not(gt(x, y))
}

/*
 * General comparison: returned value is -1, 0 or 1, depending on
 * whether x is lower than, equal to, or greater than y.
 */
cmp :: #force_inline proc "contextless" (x, y: u32) -> (res: i32) {
	return i32(gt(x, y)) | -i32(gt(y, x))
}

/*
 * Returns 1 if x == 0, 0 otherwise. Take care that the operand is signed.
 */
eq0 :: #force_inline proc "contextless" (x: i32) -> (res: u32) {
	q := u32(x)
	return ~(q | -q) >> 31
}

/*
 * Returns 1 if x > 0, 0 otherwise. Take care that the operand is signed.
 */
gt0 :: #force_inline proc "contextless" (x: i32) -> (res: u32) {
	/*
	 * High bit of -x is 0 if x == 0, but 1 if x > 0.
	 */
	q := u32(x)
	return (~q & -q) >> 31
}

/*
 * Returns 1 if x >= 0, 0 otherwise. Take care that the operand is signed.
 */
ge0 :: #force_inline proc "contextless" (x: i32) -> (res: u32) {
	return ~u32(x) >> 31
}

/*
 * Returns 1 if x < 0, 0 otherwise. Take care that the operand is signed.
 */
lt0 :: #force_inline proc "contextless" (x: i32) -> (res: u32) {
	return u32(x) >> 31
}

/*
 * Returns 1 if x <= 0, 0 otherwise. Take care that the operand is signed.
 */
le0 :: #force_inline proc "contextless" (x: i32) -> (res: u32) {
	/*
	 * ~-x has its high bit set if and only if -x is nonnegative (as
	 * a signed int), i.e. x is in the -(2^31-1) to 0 range. We must
	 * do an OR with x itself to account for x = -2^31.
	 */
	q := u32(x)
	return (q | ~-q) >> 31
}

/*
 * Compute the minimum of x and y.
 */
min :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	return mux(gt(x, y), y, x)
}

/*
 * Compute the maximum of x and y.
 */
max :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	return mux(gt(x, y), x, y)
}

/*
 * Compute the bit length of a 32-bit integer. Returned value is between 0
 * and 32 (inclusive).
 */
bit_length :: #force_inline proc "contextless" (x: u32) -> (length: u32) {
	x := x
	k := neq(x, 0)
	c := gt(x, 0xFFFF); x = mux(c, x >> 16, x); k += c << 4
	c  = gt(x, 0x00FF); x = mux(c, x >>  8, x); k += c << 3
	c  = gt(x, 0x000F); x = mux(c, x >>  4, x); k += c << 2
	c  = gt(x, 0x0003); x = mux(c, x >>  2, x); k += c << 1
	k += gt(x, 0x0001)
	return k
}

/*
 * Multiply two 32-bit integers, with a 64-bit result. This default
 * implementation assumes that the basic multiplication operator
 * yields constant-time code.
 */
mul :: #force_inline proc "contextless" (x, y: u32) -> (res: u64) {
	return u64(x) * u64(y)
}

/*
 * Multiply two 31-bit integers, with a 62-bit result. This default
 * implementation assumes that the basic multiplication operator
 * yields constant-time code.
 * The mul31_lo() returns only the low 31 bits of the product.
 */
hw_mul31 :: #force_inline proc "contextless" (x, y: u32) -> (res: u64) {
	return u64(x) * u64(y)
}

hw_mul31_lo :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	return (x * y) & I31_MASK
}

/*
 * Alternate implementation of MUL31, that will be constant-time on some
 * (old) platforms where the default MUL31 is not. Unfortunately, it is
 * also substantially slower, and yields larger code, on more modern
 * platforms, which is why it is deactivated by default.
 *
 * MUL31_lo() must do some extra work because on some platforms, the
 * _signed_ multiplication may return early if the top bits are 1.
 * Simply truncating (casting) the output of MUL31() would not be
 * sufficient, because the compiler may notice that we keep only the low
 * word, and then replace automatically the unsigned multiplication with
 * a signed multiplication opcode.
 */

sw_mul31 :: #force_inline proc "contextless" (x, y: u32) -> (res: u64) {
	x64 := u64(x)
	y64 := u64(y)
	return (x64 | I31_HI_MASK) * (y64 | I31_HI_MASK) - (x64 << 31) - (y64 << 31) - (1 << 62)
}

sw_mul31_lo :: #force_inline proc "contextless" (x, y: u32) -> (res: u32) {
	xl := (x & I31_LO_MASK) | I31_HI_MASK
	xh := (x >> 16)         | I31_HI_MASK
	yl := (y & I31_LO_MASK) | I31_HI_MASK
	yh := (y >> 16)         | I31_HI_MASK

	return (xl * yl + ((xl * yh + xh * yl) << 16)) & I31_MASK
}