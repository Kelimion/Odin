package datetime

// Internal helper functions for calendrical conversions

import "core:intrinsics"

sign :: proc(v: int) -> (res: int) {
	if v == 0 {
		return 0
	} else if v > 0 {
		return 1
	}
	return -1
}

divmod :: proc(x, y: $T) -> (a: T, r: T)
	where intrinsics.type_is_integer(T) {
	assert(y != 0, "Division by zero")

	a = x / y
	r = x % y
	if (r > 0 && y < 0) || (r < 0 && y > 0) {
		a -= 1
		r += y
	}
	return a, r
}

// Divides and floors
floor_div :: proc "contextless" (x, y: $T) -> (res: T)
	where intrinsics.type_is_integer(T) {
	res = x / y
	r  := x % y
	if (r > 0 && y < 0) || (r < 0 && y > 0) {
		res -= 1
	}
	return res
}

// Half open: x mod [1..b]
interval_mod :: proc(x, a, b: int) -> (res: int) {
	if a == b {
		return x
	}
	return a + ((x - a) %% (b - a))
}

// x mod [1..b]
adjusted_remainder :: proc(x, b: int) -> (res: int) {
	m := x %% b
	return b if m == 0 else m
}

gcd :: proc(x, y: int) -> (res: int) {
	if y == 0 {
		return x
	}

	m := x %% y
	return gcd(y, m)
}

lcm :: proc(x, y: int) -> (res: int) {
	return x * y / gcd(x, y)
}

sum :: proc(i: int, f: proc(n: int) -> int, cond: proc(n: int) -> bool) -> (res: int) {
	for idx := i; cond(idx); idx += 1 {
		res += f(idx)
	}
	return
}

product :: proc(i: int, f: proc(n: int) -> int, cond: proc(n: int) -> bool) -> (res: int) {
	res = 1
	for idx := i; cond(idx); idx += 1 {
		res *= f(idx)
	}
	return
}

smallest :: proc(k: int, cond: proc(n: int) -> bool) -> (d: int) {
	k := k
	for !cond(k) {
		k += 1
	}
	return k
}

biggest :: proc(k: int, cond: proc(n: int) -> bool) -> (d: int) {
	k := k
	for !cond(k) {
		k -= 1
	}
	return k
}