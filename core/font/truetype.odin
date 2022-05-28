package core_font

import "core:os"
import "core:intrinsics"
import "core:strings"
import "core:mem"
import "core:fmt"

_ :: fmt

//////////////////////////////////////////////////////////////////////////////
//
// TEXTURE BAKING API
//
// If you use this API, you only have to call two functions ever.
//

/*
	Inputs:
		`data`         Byte data of TTF/TTC/OTF file. Offset as neccessary to load a font in a TTC collection.
		`pixel_height` Pixel height.

	Outputs:
		`atlas`        Atlas with baked image and bounding boxes into the image for each rune.
		`err`          Error. Returns `nil` if no error.

	This uses very crappy packing.
*/

bake_font_data_to_atlas :: proc(data: []u8, pixel_height: f32, first_character: rune, num_chars: int) -> (atlas: ^Atlas, err: Error) {
	return
}

bake_font_file_to_atlas :: proc(filename: string, pixel_height: f32, first_character: rune, num_chars: int) -> (atlas: ^Atlas, err: Error) {
	return
}

bake_font_to_atlas :: proc {bake_font_data_to_atlas, bake_font_file_to_atlas}

/*
	Inputs:
		`atlas`              Atlas with baked image and bounding boxes into the image for each rune.
		`char`               Rune to display
		`xpos`, `ypos`       Pointers to the current position in screen pixel space, advanced with each requested rune.
		`opengl_fill_rule`: `true` for OpenGL fill rule, false if DX9 or earlier.

	Outputs:
		`quad`               Aligned quad to draw
		`err`                Error. Returns `nil` if no error.

	Call `get_baked_quad` with the character you want, and it creates the quad you need to draw and advances the current position.
	The coordinate system used assumes y increases downwards.

	Characters will extend both above and below the current position; see discussion of "BASELINE" above.
	It's inefficient; you might want to c&p it and optimize it.
*/
get_baked_quad :: proc(atlas: ^Atlas, char: rune, x_pos, y_pos: ^f32, opengl_fill_rule: bool) -> (quad: Aligned_Quad, err: Error) {


	return
}

//////////////////////////////////////////////////////////////////////////////
//
// NEW TEXTURE BAKING API
//
// This provides options for packing multiple fonts into one atlas, not
// perfectly but better than nothing.

// Given an offset into the file that defines a font, this function builds
// the necessary cached info for the rest of the system. You must allocate
// the stbtt_fontinfo yourself, and stbtt_InitFont will fill it out. You don't
// need to do anything special to free it, because the contents are pure
// value data with no additional data structures. Returns 0 on failure.
init_font_from_bytes :: proc(data: []u8, index: int) -> (font: ^Font_Info, err: Error) {
	num_fonts := get_number_of_fonts(data) or_return

	if index > num_fonts {
		return nil, .Invalid_Font_Index
	}

	offset := get_font_offset_for_index(data, index) or_return

	font = new(Font_Info)
	font.data = data
	font.font_start = i32(offset)

	strings.intern_init(&font.intern)
	init_and_checksum_tables(font) or_return

	cmap := font.tables["cmap"]
	glyf := font.tables["glyf"]
	loca := font.tables["loca"]
	head := font.tables["head"]

	if glyf.offset > 0 {
		// required for truetype
		if loca.offset == 0 {
			return font, .Required_Table_Missing
		}
	} else {
		// initialization for CFF / Type2 fonts (OTF)

		cff := font.tables["CFF "]
		if cff.offset == 0 {
			return font, .Required_Table_Missing
		}

		if int(cff.offset) + int(cff.length) > len(data) {
			return font, .Corrupt_CFF
		}

		font.cff = new_buf(data[cff.offset:], i32(cff.length))
		b := font.cff

		// read the header
		skip(&b, 2)
		seek(&b, get8(&b)) // hdrsize

		// @TODO the name INDEX could list multiple fonts,
		// but we just use the first one.
		cff_get_index(&b) or_return  // name INDEX

		topdictidx := cff_get_index(&b) or_return
		topdict    := cff_index_get(&topdictidx, 0) or_return
		cff_get_index(&b) or_return  // string INDEX
		font.gsubrs = cff_get_index(&b) or_return

		charstrings, cstype, fdarrayoff, fdselectoff: [1]u32
		cstype[0] = 2 // Default value

		dict_get_ints(&topdict, 17,         charstrings[:])
		dict_get_ints(&topdict, 0x100 | 6,  cstype[:])
		dict_get_ints(&topdict, 0x100 | 36, fdarrayoff[:])
		dict_get_ints(&topdict, 0x100 | 37, fdselectoff[:])

		font.subrs = get_subrs(&b, &topdict) or_return

		// we only support Type 2 charstrings
		if cstype != 2 || charstrings[0] == 0 {
			return font, .Unsupported_Charstring
		}

		if fdarrayoff[0] > 0 {
			// looks like a CID font
			if fdselectoff[0] == 0 {
				return font, .Unsupported_CID_Font
			}

			seek(&b, i32(fdarrayoff[0]))
			font.fontdicts = cff_get_index(&b) or_return
			font.fdselect  = range(&b, i32(fdselectoff[0]), i32(len(b.data)) - i32(fdselectoff[0]))
		}

		seek(&b, i32(charstrings[0]))
		font.charstrings = cff_get_index(&b) or_return
	}

	maxp := font.tables["maxp"]
	if maxp.length > 0 {
		if int(maxp.offset + 6) < len(data) {
			font.num_glyphs = get16(data, i32(maxp.offset + 4))
		}
	} else {
		font.num_glyphs = 0xffff
	}

	// find a cmap encoding table we understand *now* to avoid searching
	// later. (todo: could make this installable)
	// the same regardless of glyph.
	num_tables := get16(data, i32(cmap.offset) + 2)
	for i in 0..<num_tables {
		encoding_record := i32(cmap.offset) + 4 + 8 * i

		// find an encoding we understand:
		#partial switch Platform_ID(get16(data, encoding_record)) {
		case .Microsoft:
				#partial switch Platform_MS_Encoding_ID(get16(data, encoding_record + 2)) {
				case .Unicode_BMP, .Unicode_Full:
					// MS / Unicode
					font.index_map = u32(cmap.offset) + u32(slice_get32(data, encoding_record + 4))
					break
				}
				break
		case .Unicode:
				// Mac/iOS has these
				// all the encodingIDs are unicode, so we don't bother to check it
				font.index_map = u32(cmap.offset) + u32(slice_get32(data, encoding_record + 4))
				break
		}
	}

	if font.index_map == 0 {
		return font, .Could_Not_Locate_Index_Map
	}

	font.index_to_loc_format = u32(get16(data, i32(head.offset) + 50))
	return
}

init_font_from_file :: proc(file: string, index: int) -> (font: ^Font_Info, err: Error) {
	data, data_ok := os.read_entire_file(file)
	if !data_ok {
		delete(data)
		return {}, .Unable_To_Load_Font
	}
	return init_font_from_bytes(data, index)
}

init_font :: proc{init_font_from_bytes, init_font_from_file}

init_and_checksum_tables :: proc(font: ^Font_Info) -> (err: Error) {
	num_records := int(peek_u16(font.data[font.font_start+4:]))
	table_dir   := int(font.font_start + 12)

	for i in 0..<num_records {
		loc := table_dir + 16 * i

		record := get_type(font.data[loc:], Table_Record) or_return
		tag    := strings.intern_get(&font.intern, string(record.tag[:]))

		// A table should be 4-byte aligned.
		if record.offset & 3 != 0 {
			return .Invalid_Alignment
		}

		// Check the table fits within the file data
		check_length := (int(record.length) + 3) ~3
		if int(record.offset) + int(check_length) > len(font.data) {
			return .Table_Corrupt
		}

		// Check the table doesn't overlap with already found tables
		this_start := int(record.offset)
		this_end   := int(record.offset) + int(record.length)

		for other_tag, v in font.tables {
			if tag == other_tag {
				continue
			}

			other_start := int(v.offset)
			other_end   := int(v.offset) + int(v.length)

			if this_start >= other_start && this_start < other_end {
				return .Table_Corrupt
			}

			if this_end > other_start && this_end < other_end {
				return .Table_Corrupt
			}
		}

		if tag != "head" {
			checksum     := u32be(0)

			table_data := mem.slice_data_cast([]u32be, font.data[record.offset:][:check_length])
			for v in table_data {
				checksum += v
			}

			if checksum != record.checksum {
				return .Table_Checksum_Failed
			}
		}
		font.tables[tag] = record
	}

	for tag in REQUIRED_TABLES {
		if tag not_in font.tables {
			return .Required_Table_Missing
		}
	}

	if font.tables["head"].length != size_of(Font_Header_Table) {
		return .Table_Corrupt
	}

	if font.tables["hhea"].length != size_of(Horizontal_Header_Table) {
		return .Table_Corrupt
	}
	return
}

// Returns 1 for a single font, 2 for a font collection (TTC)
// or 0 when not recognized or supported
is_font :: proc(data: []u8) -> (font: int) {
	switch tag(data) {
	// Single Font
	case "1\x00\x00\x00":    return 1 // TrueType 1
	case "ftyp":             return 1 // TrueType with Type 1
	case "OTTO":             return 1 // OpenType with CFF
	case "\x00\x01\x00\x00": return 1 // OpenType 1
	case "true":             return 1 // Apple TrueType

	// Font collections
	case "ttcf":             return 2 // TTF Font Collection
	}
	return
}

destroy_font :: proc(font: ^Font_Info) {
	if font == nil { return }

	strings.intern_destroy(&font.intern)
	delete(font.tables)

	delete(font.data)
	free(font)
}

get_font_offset_for_index_from_bytes :: proc(data: []u8, index: int) -> (offset: int, err: Error) {
	// if it's just a font, there's only one valid index
	font_kind := is_font(data)

	if font_kind == 1 {
		if index == 0 {
			return 0, .None
		}
		return -1, .Invalid_Font_Index
	} else if font_kind == 2 {
		// TTC font collection. Version 1?
		if len(data) < 12 {
			return -1, .Not_Enough_Data
		}

		t := peek_u32(data[4:])
		if t == 0x00010000 || t == 0x00020000 {
			if index >= int(peek_u32(data[8:])) {
				return -1, .Invalid_Font_Index
			}

			if len(data) < 16 + index * 4 {
				return -1, .Not_Enough_Data
			}
			return int(peek_u32(data[12 + index * 4:])), .None
		}
	}
	return -1, .Not_A_Supported_Font
}

get_font_offset_for_index_from_font_info :: proc(font: ^Font_Info, index: int) -> (offset: int, err: Error) {
	if font == nil {
		return -1, .Not_A_Supported_Font
	}
	return get_font_offset_for_index_from_bytes(font.data, index)
}

get_font_offset_for_index :: proc{ get_font_offset_for_index_from_bytes, get_font_offset_for_index_from_font_info }


// This function will determine the number of fonts in a font file.  TrueType
// collection (.ttc) files may contain multiple fonts, while TrueType font
// (.ttf) files only contain one font. The number of fonts can be used for
// indexing with the previous function where the index is between zero and one
// less than the total fonts. If an error occurs, -1 is returned.
get_number_of_fonts_from_bytes :: proc(data: []u8) -> (font_count: int, err: Error) {
	// if it's just a font, there's only one valid index
	font_kind := is_font(data)

	if font_kind == 1 {
		return 1, .None
	} else if font_kind == 2 {
		// TTC font collection. Version 1?
		if len(data) < 12 {
			return -1, .Not_Enough_Data
		}

		t := peek_u32(data[4:])
		if t == 0x00010000 || t == 0x00020000 {
			return int(peek_u32(data[8:])), .None
		}
	}
	return 0, .Not_A_Supported_Font
}

get_number_of_fonts_from_bytes_from_font_info :: proc(font: ^Font_Info) -> (font_count: int, err: Error) {
	if font == nil {
		return -1, .Unable_To_Load_Font
	}
	return get_number_of_fonts_from_bytes(font.data)
}

get_number_of_fonts :: proc{ get_number_of_fonts_from_bytes, get_number_of_fonts_from_bytes_from_font_info }

// Get the glyph index from a rune. Many of the procedures take a glyph index.
// Returns 0 if font doesn't provide the glyph in question
find_glyph_index :: proc(font: ^Font_Info, codepoint: rune) -> (glyph_index: int, err: Error) {
	data      := font.data
	index_map := i32(font.index_map)
	format    := get16(data, i32(index_map))

	switch format {
	case 0: // apple byte encoding
		bytes := get16(data, index_map + 2)
		if i32(codepoint) < bytes - 6 {
			return int(get8(data, i32(index_map) + 6 + i32(codepoint))), .None
		}
		return 0, .None

	case 2: // @TODO: high-byte mapping for japanese/chinese/korean
		return 0, .Unsupported_Character_Map_Format

	case 4: // standard mapping for windows fonts: binary search collection of ranges
		segcount       := get16(data, index_map + 6) >> 1
		search_range   := get16(data, index_map + 8) >> 1
		entry_selector := get16(data, index_map + 10)
		range_shift    := get16(data, index_map + 12) >> 1

		// do a binary search of the segments
		end_count := index_map + 14
		search    := end_count

		if codepoint > 0xffff {
			return 0, .None
		}

		// they lie from endCount .. endCount + segCount
		// but searchRange is the nearest power of two, so...
		if i32(codepoint) >= get16(data, search + range_shift * 2) {
			search += range_shift * 2
		}

		// now decrement to bias correctly to find smallest
		search -= 2
		for entry_selector > 0 {
			search_range >>= 1
			end := get16(data, search + search_range * 2)
			if i32(codepoint) > end {
				search += search_range * 2
			}
			entry_selector -= 1
		}
		search += 2

		item := (search - end_count) >> 1
		start := get16(data, index_map + 14 + (segcount + item) * 2 + 2)
		last  := get16(data, end_count +  2 * item)

		if i32(codepoint) < start || i32(codepoint) > last {
			return 0, .None
		}

		offset := get16(data, index_map + 14 + segcount * 6 + 2 + 2 * item)
		if offset == 0 {
			return int(codepoint) + int(get16(data, index_map + 14 + segcount * 4 + 2 + 2 * item)), .None
		}
		return int(get16(data, offset + (i32(codepoint) - start) * 2 + index_map + 14 + segcount * 6 + 2 + 2 * item)), .None

	case 6:
		first := get16(data, index_map + 6)
		count := get16(data, index_map + 8)

		if i32(codepoint) >= first && i32(codepoint) < first + count {
			return int(get16(data, index_map + 10 + (i32(codepoint) - first) * 2)), .None
		}
		return 0, .None

	case 12, 13:
		ngroups := get32(data, index_map + 12)

		low  := i32(0)
		high := ngroups

		// Binary search the right group.
		for low < high {
			mid := low + ((high - low) >> 1) // rounds down, so low <= mid < high

			start_char := get32(data, index_map + 16 + mid * 12)
			end_char   := get32(data, index_map + 16 + mid * 12 + 4)

			if i32(codepoint) < start_char {
				high = mid
			} else if i32(codepoint) > end_char {
				low = mid + 1
			} else {
				start_glyph := get32(data, index_map + 16 + mid * 12 + 8)
				if format == 12 {
					return int(start_glyph) + int(codepoint) - int(start_char), .None
				} else {
					// format == 13
					return int(start_glyph), .None
				}
			}
		}
		return 0, .None // not found
	}
	return 0, .Unsupported_Character_Map_Format
}

// platform_id, encoding_id, language_id can be set to -1 to match the first such entry
get_font_name :: proc(font: ^Font_Info, platform_id, encoding_id, language_id, name_id: int) -> (name: string, is_utf8: bool, err: Error) {
	name_table := font.tables["name"]

	if name_table.length == 0 {
		return {}, false, .None
	}

	t := get_type(font.data[name_table.offset:], Font_Naming_Table_Header) or_return

	for i in 0..<t.count {
		name_record_offset := int(name_table.offset) + 6 + size_of(Name_Record) * int(i)

		if name_record_offset > len(font.data) {
			err = .Not_Enough_Data
			return
		}

		name := get_type(font.data[name_record_offset:], Name_Record) or_return

		if platform_id != -1 && platform_id != int(name.platform_id) {
			// Not the right platform
			continue
		}

		if encoding_id != -1 && encoding_id != int(name.encoding_id) {
			// Not the right encoding id
			continue
		}

		if language_id != -1 && language_id != int(name.language_id) {
			// Not the right language id
			continue
		}

		if name_id != int(name.name_id) {
			// Not the requested name
			continue
		}

		string_offset := int(name_table.offset) + int(t.storage_offset) + int(name.offset)
		if string_offset + int(name.length) > len(font.data) {
			err = .Not_Enough_Data
			return
		}

		name_data := font.data[string_offset:][:name.length]

		#partial switch name.platform_id {
		case .Microsoft:
			#partial switch Platform_MS_Encoding_ID(name.encoding_id) {
			case .Unicode_BMP:	// UTF16 Big Endian
				s := utf16be_to_utf8(name_data) or_return
				return s, true, .None

			case:
				return strings.clone(string(name_data)), false, .None
			}

		case .Macintosh:
			return strings.clone(string(name_data)), true, .None

		case .Unicode:
			s := utf16be_to_utf8(name_data) or_return
			return s, true, .None
		}
	}
	return {}, false, .None
}

// Query the font vertical metrics without having to create a font first.
get_scaled_vertical_metrics_from_font_data :: proc(data: []u8, size: f32, font_index := 0) -> (ascent, descent, line_gap: f32, err: Error) {
	font := init_font(data, font_index) or_return
	defer destroy_font(font)

	scale: f32
	if size > 0 {
		scale = scale_for_pixel_height(font, size) or_return
	} else {
		scale = scale_for_mapping_em_to_pixels(font, size) or_return
	}

	_ascent, _descent, _line_gap := get_vertical_metrics(font) or_return

	return f32(_ascent) * scale, f32(_descent) * scale, f32(_line_gap) * scale, .None
}

// computes a scale factor to produce a font whose "height" is 'pixels' tall.
// Height is measured as the distance from the highest ascender to the lowest
// descender; in other words, it's equivalent to calling stbtt_GetFontVMetrics
// and computing:
//       scale = pixels / (ascent - descent)
// so if you prefer to measure height by the ascent only, use a similar calculation.
scale_for_pixel_height :: proc(font: ^Font_Info, pixels: f32) -> (scale: f32, err: Error) {
	offset := font.tables["hhea"].offset + 4
	values := get_type(font.data[offset:], [2]FWORD) or_return

	if values[0] == values[1] {
		// Would cause division by zero
		return 0, .Table_Corrupt
	}

	fheight := f32(values[0] - values[1])
	return pixels / fheight, .None
}

// computes a scale factor to produce a font whose EM size is mapped to
// 'pixels' tall. This is probably what traditional APIs compute, but I'm not positive.
scale_for_mapping_em_to_pixels :: proc(font: ^Font_Info, pixels: f32) -> (scale: f32, err: Error) {
	offset       := font.tables["head"].offset + 18
	units_per_em := get_type(font.data[offset:], FWORD) or_return

	if units_per_em == 0 {
		// Would cause division by zero
		return 0, .Table_Corrupt
	}
	return pixels / f32(units_per_em), .None
}

// ascent is the coordinate above the baseline the font extends; descent
// is the coordinate below the baseline the font extends (i.e. it is typically negative)
// lineGap is the spacing between one row's descent and the next row's ascent...
// so you should advance the vertical position by "*ascent - *descent + *lineGap"
//   these are expressed in unscaled coordinates, so you must multiply by
//   the scale factor for a given size
get_vertical_metrics :: proc(font: ^Font_Info) -> (ascent, descent, line_gap: int, err: Error) {
	hhea := get_type(font.data[font.tables["hhea"].offset:], Horizontal_Header_Table) or_return
	return int(hhea.ascender), int(hhea.descender), int(line_gap), .None
}

// analogous to GetFontVMetrics, but returns the "typographic" values from the OS/2
// table (specific to MS/Windows TTF files).
//
// Returns 1 on success (table present), 0 on failure.
get_vertical_metrics_os2 :: proc(font: ^Font_Info) -> (ascent, descent, line_gap: int, ok: bool, err: Error) {
	if "OS/2" not_in font.tables {
		return
	}
	tab := font.tables["OS/2"]

	offset := int(tab.offset + 68)
	values := get_type(font.data[offset:], [3]i16be) or_return

	return int(values[0]), int(values[1]), int(values[2]), true, .None
}

// the bounding box around all possible characters
get_font_bounding_box :: proc(font: ^Font_Info) -> (bbox: Bounding_Box, err: Error) {
	offset := font.tables["head"].offset + 36

	values := get_type(font.data[offset:], [4]i16be) or_return
	_bbox  := [4]i16{i16(values[0]), i16(values[1]), i16(values[2]), i16(values[3])}

	return transmute(Bounding_Box)_bbox, .None
}

// leftSideBearing is the offset from the current horizontal position to the left edge of the character
// advanceWidth is the offset from the current horizontal position to the next horizontal position
//   these are expressed in unscaled coordinates
get_glyph_horizontal_metrics :: proc(font: ^Font_Info, glyph: int) -> (advance_width, left_side_bearing: int, err: Error) {
	hhea_offset := font.tables["hhea"].offset + 34
	number_of_hmetrics := get16(font.data, i32(hhea_offset))

	hm := i32(number_of_hmetrics)

	hmtx_offset := i32(font.tables["hmtx"].offset)

	if glyph < int(number_of_hmetrics) {
		advance_width     = int(get16(font.data, hmtx_offset + 4 * i32(glyph)))
		left_side_bearing = int(get16(font.data, hmtx_offset + 4 * i32(glyph) + 2))
	} else {
		advance_width     = int(get16(font.data, hmtx_offset + 4 * (hm - 1)))
		left_side_bearing = int(get16(font.data, hmtx_offset + 4 * hm + 2 * (i32(glyph) - hm)))
	}
	return
}

get_rune_horizontal_metrics :: proc(font: ^Font_Info, codepoint: rune) -> (advance_width, left_side_bearing: int, err: Error) {
	glyph := find_glyph_index(font, codepoint) or_return
	return get_glyph_horizontal_metrics(font, glyph)
}

// an additional amount to add to the 'advance' value between ch1 and ch2
get_glyph_kern_advance :: proc(font: ^Font_Info, glyph1, glyph2: int) -> (kern: int, err: Error) {
	return
}

// an additional amount to add to the 'advance' value between ch1 and ch2
get_rune_kern_advance :: proc(font: ^Font_Info, ch1, ch2: rune) -> (kern: int, err: Error) {
	return
}

// Gets the bounding box of the visible part of the glyph, in unscaled coordinates
get_rune_box :: proc(font: ^Font_Info, codepoint: rune) -> (x0, y0, x1, y1: i32, err: Error) {
	return
}