//+private
package core_font

import "core:intrinsics"
import "core:unicode/utf16"
import "core:mem"
import "core:strings"

peek8 :: proc(b: ^Buf) -> (res: i32) {
	if int(b.cursor) >= len(b.data) {
		return
	}
	return i32(b.data[b.cursor])
}

seek :: proc(b: ^Buf, o: i32) {
	b.cursor = i32(len(b.data)) if (o > i32(len(b.data)) || o < 0) else o
}

skip :: proc(b: ^Buf, o: i32) {
	seek(b, b.cursor + o)
}

new_buf_from_buf :: proc(b: ^Buf, size: i32) -> (res: Buf) {
	assert(size < 0x40000000)
	res.data = b.data[:size]
	return
}

new_buf_from_slice :: proc(b: []u8, size: i32) -> (res: Buf) {
	assert(size < 0x40000000)
	res.data = b[:size]
	return
}
new_buf :: proc{new_buf_from_slice, new_buf_from_buf}

cff_get_index :: proc(b: ^Buf) -> (res: Buf, err: Error) {
	start := b.cursor
	count := get16(b) or_return

	if count > 0 {
		offsize := get8(b)
		if offsize < 1 || offsize > 4 {
			return {}, .Corrupt_CFF
		}

		skip(b, offsize * count)
		_off := get(b, offsize) or_return
		skip(b, _off - 1)
	}
	return range(b, start, b.cursor - start), .None
}

cff_index_get :: proc(b: ^Buf, i: i32) -> (res: Buf, err: Error) {
	seek(b, 0)

	count   := get16(b) or_return
	offsize := get8(b)

	if i < 0 || i >= count || offsize < 1 || offsize > 4 {
		return {}, .Corrupt_CFF
	}

	skip(b, i * offsize)
	start := get(b, offsize) or_return
	end   := get(b, offsize) or_return
	return range(b, 2 + (count+1) * offsize + start, end - start), .None
}

cff_int :: proc(b: ^Buf) -> (res: i32, err: Error) {
	b0 := get8(b)

	switch {
	case b0 >= 32 && b0 <= 246:
		return b0 - 139, .None
	case b0 >= 247 && b0 <= 250:
		return  (b0 - 247) * 256 + get8(b) + 108, .None
	case b0 >= 251 && b0 <= 254:
		return -(b0 - 251) * 256 - get8(b) - 108, .None
	case b0 == 28:
		t := get16(b) or_return
		return i32(transmute(i16)u16(t)), .None
	case b0 == 29:
		return get32(b)
	}
	return res, .Corrupt_CFF
}

cff_skip_operand :: proc(b: ^Buf) -> (err: Error) {
	b0 := peek8(b)
	if b0 < 28 {
		return .Corrupt_CFF
	}

	if b0 == 30 {
		skip(b, 1)

		for int(b.cursor) < len(b.data) {
			v := get8(b)
			if ((v & 0xF) == 0xF || (v >> 4) == 0xF) {
				break
			}
		}
	} else {
		cff_int(b) or_return
	}
	return .None
}

cff_index_count :: proc(b: ^Buf) -> (res: i32, err: Error) {
	seek(b, 0)
	return get16(b)
}

dict_get :: proc(b: ^Buf, key: i32) -> (res: Buf, err: Error) {
	seek(b, 0)

	for int(b.cursor) < len(b.data) {
		start := b.cursor

		for peek8(b) >= 28 {
			cff_skip_operand(b)
		}

		end := b.cursor
		op  := get8(b)

		if op == 12  { op = get8(b) | 0x100 }
		if op == key { return range(b, start, end-start), .None }
	}

	return range(b, 0, 0), .None
}

dict_get_ints :: proc(b: ^Buf, key: i32, out: []u32) -> (err: Error) {
	operands := dict_get(b, key) or_return

	for i := 0; i < len(out) && int(operands.cursor) < len(operands.data); i += 1 {
		v := cff_int(&operands) or_return
		out[i] = transmute(u32)v
	}
	return .None
}

get_subrs :: proc(cff: ^Buf, fontdict: ^Buf) -> (res: Buf, err: Error) {
	private_loc: [2]u32
	subrsoff: [1]u32

	dict_get_ints(fontdict, 18, private_loc[:])

	if private_loc[1] == 0 || private_loc[0] == 0 {
		return // Return empty buffer
	}

	pdict := range(cff, i32(private_loc[1]), i32(private_loc[0]))
	dict_get_ints(&pdict, 19, subrsoff[:])

	if subrsoff[0] == 0 {
		return // Return empty buffer
	}

	seek(cff, i32(private_loc[1] + subrsoff[0]))

	return cff_get_index(cff)
}

buf_get_type :: proc(b: ^Buf, $T: typeid) -> (res: T, err: Error) {
	if len(b.data) < size_of(T) {
		return {}, .Not_Enough_Data
	}
	res = slice_get_type(b.data[b.cursor:], T) or_return
	b.cursor += size_of(T)
	return res, .None
}

slice_get_type :: proc(data: []u8, $T: typeid) -> (res: T, err: Error) {
	if len(data) < size_of(T) {
		return {}, .Not_Enough_Data
	}

	ptr := (^T)(raw_data(data))
	return intrinsics.unaligned_load(ptr), .None
}
get_type :: proc{slice_get_type, buf_get_type}


get :: proc(b: ^Buf, n: i32) -> (res: i32, err: Error) {
	switch n {
	case 4:
		v := get_type(b, i32be) or_return
		return i32(v), .None

	case 3:
		v1 := get_type(b, u8) or_return
		v2 := get_type(b, u8) or_return
		v3 := get_type(b, u8) or_return

		return i32(v1) << 16 | i32(v2) << 8 | i32(v3), .None

	case 2:
		v := get_type(b, i16be) or_return
		return i32(v), .None

	case 1:
		v := get_type(b, u8) or_return
		return i32(v), .None

	case:
		assert(false, "get range is 1..=4")
	}
	unreachable()
}

buf_get8 :: proc(b: ^Buf) -> (res: i32) {
	if int(b.cursor) >= len(b.data) {
		return
	}
	res = i32(b.data[b.cursor])
	b.cursor += 1
	return
}

slice_get8 :: proc(b: []u8, offset: i32) -> (res: i32) {
	if int(offset) < len(b) {
		res = i32(b[offset])
	}
	return
}

get8 :: proc{buf_get8, slice_get8}

buf_get16 :: proc(b: ^Buf) -> (res: i32, err: Error) {
	v := get_type(b, i16be) or_return
	return i32(v), .None
}

slice_get16 :: proc(b: []u8, offset: i32) -> (res: i32) {
	if int(offset) + 1 < len(b) {
		res = i32(b[offset]) * 256 + i32(b[offset + 1])
	}
	return
}
get16 :: proc{buf_get16, slice_get16}

buf_get32 :: proc(b: ^Buf) -> (res: i32, err: Error) {
	v := get_type(b, i32be) or_return
	return i32(v), .None
}

slice_get32 :: proc(b: []u8, offset: i32) -> (res: i32) {
	if int(offset) + 3 < len(b) {
		res = i32(b[offset]) << 24 | i32(b[offset + 1]) << 16 | i32(b[offset + 2]) << 8 | i32(b[offset + 3])
	}
	return
}
get32 :: proc{buf_get32, slice_get32}

range :: proc(b: ^Buf, o: i32, s: i32) -> (res: Buf) {
	if o < 0 || s < 0 || int(o) > len(b.data) || int(s) > len(b.data) - int(o) {
		return
	}
	res.data = b.data[o:][:s]
	return
}

tag :: proc(data: []u8) -> (res: string) {
	if len(data) < 4 {
		return ""
	}
	return string(data[:4])
}

peek_u32 :: proc(data: []u8) -> (res: u32be) {
	if len(data) < 4 {
		return 0
	}
	return intrinsics.unaligned_load(transmute(^u32be)raw_data(data))
}

peek_u16 :: proc(data: []u8) -> (res: u16be) {
	if len(data) < 2 {
		return 0
	}
	return intrinsics.unaligned_load(transmute(^u16be)raw_data(data))
}

utf16be_to_utf8 :: proc(data: []u8) -> (res: string, err: Error) {
	_data := make([]u8, len(data))
	copy(_data, data)
	defer delete(_data)

	s := mem.slice_data_cast([]u16, _data)

	if len(data) % 2 != 0 {
		return {}, .Invalid_UTF16_Length
	}

	when ODIN_ENDIAN == .Little {
		orig := mem.slice_data_cast([]u16be, _data)

		for v, i in orig {
			s[i] = u16(v)
		}
	}

	temp := make([]u8, len(_data) * 2)
	defer delete(temp)
	n    := utf16.decode_to_utf8(temp, s)

	return strings.clone(string(temp[:n])), .None
}

f2dot_to_f32 :: proc(f: F2DOT14) -> (res: f32) {
	whole    := f32((i16(f) >> 14))
	part     := u16(f) & ((1 << 14) - 1)
	fraction := f32(part) / f32(16384)

	return whole + fraction
}