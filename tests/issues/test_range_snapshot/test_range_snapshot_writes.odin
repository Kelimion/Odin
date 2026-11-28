// A range loop whose body writes through a slice, a [dynamic] array, an #soa array, or a pointer read from outside it,
// with its indices bounds checked, reads the header once when nothing it writes can reach the header or those bases
package test_range_snapshot

import "base:runtime"
import "core:testing"

@(private="file")
RGB :: struct {
	r, g, b: u8,
}

@(private="file")
Image :: struct {
	pixels: [dynamic]u8,
	width:  int,
}

@(private="file")
draw :: proc(img: ^Image, out: []RGB, palette: []RGB) {
	for p, i in img.pixels {
		out[i] = palette[p]
	}
}

@(private="file")
Acc :: struct {
	sum:   int,
	count: int,
}

@(private="file")
accumulate :: proc(d: [dynamic]int, acc: ^Acc) {
	for x in d {
		acc.sum   += x
		acc.count += 1
	}
}

@(private="file")
P :: struct {
	x, y: f32,
}

@(private="file")
fill_soa :: proc(d: [dynamic]int, ps: #soa[]P) {
	for x, i in d {
		ps[i].x = f32(x)
		ps[i].y = f32(2*x)
	}
}

@(private="file")
add_rows :: proc(d: [dynamic]int, rows: [][4]int) {
	for x, i in d {
		rows[i][0] = x
		for y, j in d {
			rows[i][j % 4] += y
		}
	}
}

@(test)
test_writes_through_bases :: proc(t: ^testing.T) {
	img := Image{width = 4}
	defer delete(img.pixels)
	append(&img.pixels, 0, 1, 2, 0)
	palette := []RGB{{1, 2, 3}, {4, 5, 6}, {7, 8, 9}}
	out: [4]RGB
	draw(&img, out[:], palette)
	testing.expect_value(t, out, [4]RGB{{1, 2, 3}, {4, 5, 6}, {7, 8, 9}, {1, 2, 3}})

	d: [dynamic]int
	defer delete(d)
	append(&d, 1, 2, 3, 4, 5)
	acc: Acc
	accumulate(d, &acc)
	testing.expect_value(t, acc, Acc{sum = 15, count = 5})

	ps: #soa[5]P
	fill_soa(d, ps[:])
	testing.expect_value(t, ps[4], P{x = 5, y = 10})

	rows: [5][4]int
	add_rows(d, rows[:])
	testing.expect_value(t, rows[4], [4]int{11, 2, 3, 4})
}

// A slice of the array's own header: shortening the array through it ends the loop
@(test)
test_write_into_header :: proc(t: ^testing.T) {
	d: [dynamic]int
	defer delete(d)
	append(&d, 0, 1, 2, 3, 4, 5, 6, 7)
	header := ([^]int)(&d)[:3]

	n := 0
	for _, i in d {
		n += 1
		if i == 1 {
			header[1] = 3
		}
	}
	testing.expect_value(t, n, 3)
}

// The slice written through is pointed somewhere else part way through
@(test)
test_redirected_base :: proc(t: ^testing.T) {
	d: [dynamic]int
	defer delete(d)
	append(&d, 1, 2, 3, 4)
	a, b: [4]int
	out := a[:]
	p   := &out
	for x, i in d {
		out[i] = x
		if i == 1 {
			p^ = b[:]
		}
	}
	testing.expect_value(t, a, [4]int{1, 2, 0, 0})
	testing.expect_value(t, b, [4]int{0, 0, 3, 4})
}

@(private="file")
Buffered :: struct {
	buf: [4]int,
	d:   [dynamic]int,
}

// Without a bounds check, a write past the slice can reach the header
@(test)
test_unchecked_write :: proc(t: ^testing.T) {
	s: Buffered
	defer delete(s.d)
	append(&s.d, 0, 1, 2, 3, 4, 5, 6, 7)
	out := s.buf[:]

	n := 0
	#no_bounds_check for _, i in s.d {
		n += 1
		if i == 0 {
			out[5] = 2 // `s.d`'s length
		}
	}
	testing.expect_value(t, n, 2)
}

// A slice of a made up length wraps around the address space, and its bytes count as reaching everything
@(test)
test_wrapped_write :: proc(t: ^testing.T) {
	s: Buffered
	defer delete(s.d)
	append(&s.d, 0, 1, 2, 3, 4, 5, 6, 7)
	big := ([^]int)(&s.buf[0])[:(max(int) - 1)/4]

	n := 0
	for _, i in s.d {
		n += 1
		if i == 0 {
			big[5] = 2 // `s.d`'s length
		}
	}
	testing.expect_value(t, n, 2)
}

// The array's own elements reach its header, with a made up length that wraps around
@(test)
test_wrapped_elements :: proc(t: ^testing.T) {
	s: Buffered
	huge := (max(int) - 1)/4
	s.d = transmute([dynamic]int)runtime.Raw_Dynamic_Array{data = &s.buf[0], len = huge, cap = huge}

	n := 0
	for &v, i in s.d {
		n += 1
		if i == 5 {
			v = 6 // `s.d`'s length
		}
		if n > 10 {
			break
		}
	}
	testing.expect_value(t, n, 6)
}
