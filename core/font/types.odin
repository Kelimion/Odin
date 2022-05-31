package core_font

import "core:image"
import "core:strings"

MAX_OVERSAMPLE :: #config(FONT_MAX_OVERSAMPLE, 8)
#assert(MAX_OVERSAMPLE >= 1 && MAX_OVERSAMPLE <= 255, "FONT_MAX_OVERSAMPLE must be between 1 and 255 inclusive.")

RASTERIZER_VERSION :: #config(FONT_RASTERIZER_VERSION, 2)
#assert(RASTERIZER_VERSION == 1 || RASTERIZER_VERSION == 2, "FONT_RASTERIZER_VERSION must be either 1 for old or 2 for new.")

REQUIRED_TABLES :: []string{"cmap", "head", "hhea", "hmtx"}

Error :: enum {
	None = 0,
	Unable_To_Load_Font,
	Not_A_Supported_Font,
	Not_Enough_Data,
	Invalid_Font_Index,
	Required_Table_Missing,
	Table_Corrupt,
	Table_Checksum_Failed,
	Corrupt_CFF,
	Unsupported_Charstring,
	Unsupported_CID_Font,
	Could_Not_Locate_Index_Map,
	Unsupported_Character_Map_Format,
	Invalid_UTF16_Length,
	Invalid_Alignment,

}

// The following structure is defined publicly so you can declare one on
// the stack or as a global or etc, but you should treat it as opaque.
Font_Info :: struct {
	user_data:  rawptr,
	data:       []u8,
	font_start: i32,   // offset of start of font

	num_glyphs: i32,   // number of glyphs, needed for range checking

	// Table record offsets, lengths and checksums.
	tables: map[string]Table_Record,
	intern: strings.Intern,

	// a cmap mapping for our chosen character encoding
	index_map: u32,

	// format needed to map from glyph index to glyph
	index_to_loc_format: u32,

	cff:         Buf, // cff font data
	charstrings: Buf, // the charstring index
	gsubrs:      Buf, // global charstring subroutines index
	subrs:       Buf, // private charstring subroutines index
	fontdicts:   Buf, // array of font dicts
	fdselect:    Buf, // map from glyph to fontdict
}

// private structure
@(private)
Buf :: struct {
	data:   []u8,
	cursor: i32,
}

Bounding_Box :: struct {
	bottom_left: [2]i16,
	top_right:   [2]i16,
}

Aligned_Quad :: struct {
	top_left: struct {
		pos: [2]f32,
		uv:  [2]f32,
	},
	bottom_right: struct {
		pos: [2]f32,
		uv:  [2]f32,
	},
}

Packed_Rune :: struct {
	bbox: Bounding_Box,
	x_offset:   f32,
	y_offset:   f32,
	x_advance:  f32,
	x_offset_2: f32,
	y_offset_2: f32,
}


Atlas :: struct {
	img:  ^image.Image,
	bake: map[rune]Packed_Rune,
}

Table_Record :: struct {
	tag:      [4]u8,
	checksum: u32be,
	offset:   u32be,
	length:   u32be,
}

Font_Naming_Table_Header :: struct {
	version:        u16be,
	count:          u16be,
	storage_offset: u16be,
}

Name_Record :: struct {
	platform_id: Platform_ID,
	encoding_id: u16be,
	language_id: Language_ID,
	name_id:     Name_ID,
	length:      u16be,
	offset:      u16be,
}
#assert(size_of(Name_Record) == 12)

Platform_ID :: enum u16be {
	Unicode   = 0,
	Macintosh = 1,
	ISO       = 2,
	Microsoft = 3,
}

Platform_Unicode_Encoding_ID :: enum u16be {
	Unicode_1_0      = 0,
	Unicode_1_1      = 1,
	ISO_10646        = 2,
	Unicode_2_0_BMP  = 3,
	Unicode_2_0_FULL = 4,
}

Platform_MS_Encoding_ID :: enum u16be {
	Symbol       = 0,
	Unicode_BMP  = 1,
	ShiftJIS     = 2,
	Unicode_Full = 10,
}

Platform_MAC_Encoding_ID :: enum u16be {
	Roman               = 0,
	Japanese            = 1,
	Chinese_Traditional = 2,
	Korean              = 3,
	Arabic              = 4,
	Hebrew              = 5,
	Greek               = 6,
	Russian             = 7,
	RSymbol             = 8,
	Devanagari          = 9,
	Gurmukhi            = 10,
	Gujarati            = 11,
	Oriya               = 12,
	Bengali             = 13,
	Tamil               = 14,
	Telugu              = 15,
	Kannada             = 16,
	Malayalam           = 17,
	Sinhalese           = 18,
	Burmese             = 19,
	Khmer               = 20,
	Thai                = 21,
	Laotian             = 22,
	Georgian            = 23,
	Armenian            = 24,
	Chinese_Simplified  = 25,
	Tibetan             = 26,
	Mongolian           = 27,
	Geez                = 28,
	Slavic              = 29,
	Vietnamese          = 30,
	Sindhi              = 31,
	Uninterpreted       = 32,
}

Language_ID :: enum u16be {
	// languageID for STBTT_PLATFORM_ID_MICROSOFT; same as LCID...
	// problematic because there are e.g. 16 english LCIDs and 16 arabic LCIDs
	MS_ENGLISH  = 0x0409,
	MS_ITALIAN  = 0x0410,
	MS_CHINESE  = 0x0804,
	MS_JAPANESE = 0x0411,
	MS_DUTCH    = 0x0413,
	MS_KOREAN   = 0x0412,
	MS_FRENCH   = 0x040c,
	MS_RUSSIAN  = 0x0419,
	MS_GERMAN   = 0x0407,
	MS_SPANISH  = 0x0409,
	MS_HEBREW   = 0x040d,
	MS_SWEDISH  = 0x041d,

	// languageID for STBTT_PLATFORM_ID_MAC
	MAC_ENGLISH            =  0,
	MAC_FRENCH             =  1,
	MAC_GERMAN             =  2,
	MAC_ITALIAN            =  3,
	MAC_DUTCH              =  4,
	MAC_SWEDISH            =  5,
	MAC_SPANISH            =  6,
	MAC_HEBREW             = 10,
	MAC_JAPANESE           = 11,
	MAC_ARABIC             = 12,
	MAC_CHINESE_TRAD       = 19,
	MAC_KOREAN             = 23,
	MAC_RUSSIAN            = 32,
	MAC_CHINESE_SIMPLIFIED = 33,
}

Name_ID :: enum u16be {
	Copyright                    = 0,
	Font_Family                  = 1,
	Font_Subfamily               = 2,
	Unique_Font_Identifier       = 3,
	Full_Font                    = 4,
	Version                      = 5,
	Postscript                   = 6,
	Trademark                    = 7,
	Manufacturer                 = 8,
	Designer                     = 9,
	Description                  = 10,
	Vendor_URL                   = 11,
	Designer_URL                 = 12,
	License_Description          = 13,
	License_Info_URL             = 14,
	Reserved                     = 15,
	Typographic_Family           = 16,
	Typographic_Subfamily        = 17,
	Compatible_Full              = 18, // MAC only
	Sample_Text                  = 19,
	Postscript_CID_FindFont      = 20,
	WWS_Family                   = 21,
	WWS_Subfamily                = 22,
	Light_Background_Palette     = 23,
	Dark_Background_Palette      = 24,
	Variations_Postscript_Prefix = 25,
}

// TTF specific types
FWORD        :: distinct i16be
UFWORD       :: distinct u16be
Fixed        :: distinct [2]i16be
LONGDATETIME :: distinct i64be    // Number of seconds since 12:00 midnight that started January 1st 1904 in GMT/UTC time zone.
F2DOT14      :: distinct u16be

Ascender_Descender_Linegap :: struct {
	ascender:  FWORD,
	descender: FWORD,
	line_gap:  FWORD,
}

// https://docs.microsoft.com/en-us/typography/opentype/spec/hhea
Horizontal_Header_Table :: struct #packed {
	version: struct #packed {
		major: u16be,
		minor: u16be,
	},
	ascender:               FWORD,
	descender:              FWORD,
	line_gap:               FWORD,

	advance_width_max:      UFWORD,
	min_left_side_bearing:  FWORD,
	min_right_side_bearing: FWORD,

	x_max_extent:           FWORD,
	caret_slope_rise:       i16be,
	caret_slope_run:        i16be,
	caret_offset:           i16be,

	reserved:               [4]i16be,

	metric_data_format:     i16be,
	number_of_hmetrics:     u16be,
}
#assert(size_of(Horizontal_Header_Table) == 36)

// https://docs.microsoft.com/en-us/typography/opentype/spec/head
Font_Header_Table :: struct #packed {
	version: struct #packed {
		major: u16be,
		minor: u16be,
	},
	revision:            Fixed,
	checksum_adjustment: u32be,
	magic_number:        u32be, // should be 0x5F0F3CF5
	flags:               u16be,
	units_per_em:        u16be,

	created:             LONGDATETIME,
	modified:            LONGDATETIME,

	bbox: struct {
		_min: [2]i16be,
		_max: [2]i16be,
	},

	mac_style:           u16be,
	lowest_rec_ppem:     u16be,

	font_direction_hint: i16be,
	index_to_loc_format: i16be,
	glyph_data_format:   i16be,
}
#assert(size_of(Font_Header_Table) == 54)

Digital_Signature_Header_Flag :: enum u16be {
	Cannot_Be_Resigned = 0,
}
Digital_Signature_Header_Flags :: bit_set[Digital_Signature_Header_Flag; u16be]

Digital_Signature_Header :: struct {
	version:        u32be,
	num_signatures: u16be,
	flags:          Digital_Signature_Header_Flags,
}
#assert(size_of(Digital_Signature_Header) == 8)

Kerning_Entry :: struct #packed {
	glyph1:  int,
	glyph2:  int,
	advance: int,
}
#assert(size_of(Kerning_Entry) == 3 * size_of(int))

Kerning_Entry_Raw :: struct #packed {
	glyph1:  u16be,
	glyph2:  u16be,
	advance: i16be,
}
#assert(size_of(Kerning_Entry_Raw) == 6)