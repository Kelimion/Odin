package openexr

/*
	This code implements support for OpenEXR file format 2.0,
	as specified in https://www.openexr.com/documentation/openexrfilelayout.pdf
*/

EXR_FILE_VERSION_SUPPORTED :: 2;

import "core:compress"
import "core:compress/zlib"
import "core:image"

import "core:os"
import "core:strings"
// import "core:hash"
import "core:bytes"
import "core:io"
import "core:mem"
import "core:intrinsics"
import "core:fmt"

when true {
	printf :: fmt.printf;
} else {
	printf :: proc(s: string, p: ..any) {};
}

Error     :: compress.Error;
E_General :: compress.General_Error;
E_EXR     :: image.Error;
E_Deflate :: compress.Deflate_Error;

Image     :: image.Image;
Options   :: image.Options;
Context   :: compress.Context;

Signature :: enum i32le {
	EXR = 0x01312f76,
}

Version_Flag :: enum i32le {
	/*
		Bits 0..7 are used for the file format version.
	*/
	reserved_1        = 8,
	/*
		single_part_tiled:
			0: Not a single-part tiled image.
			1: Single-part tiled image.
	*/
	single_part_tiled = 9,
	/*
		long_names:
			0: maximum length of attribute, type and channel names is 31 bytes
			1: maximum length of attribute, type and channel names is 255 bytes
	*/	
	long_names        = 10,
	/*
		deep_data:
			0: All parts are entirely single or multiple scan line or tiled images
			1: At least one part contains deep data
	*/
	deep_data         = 11,
	/*
		multi_part:
			0: Not a multi-part file. End-of-header byte and part number fields omitted.
			1: Multi-part file. End-of-header bytes and part number fields must be included.
	*/
	multi_part        = 12,
}
Version_Flags :: bit_set[Version_Flag; i32le];

Version   :: struct #raw_union {
	openexr_version: u8,
	flags:           Version_Flags,
}
#assert(size_of(Version) == 4)

Info :: struct {
	type:           File_Type,
	channels:       map[string]Channel,
	// channels:       [dynamic]Channel,
	channel_order:  [dynamic]string,
	compression:    Compression_Type,

	data_window:    Box2i,
	display_window: Box2i,
	line_order:     Line_Order,
	chromacities:   Chromacities,

	// Auxillary Attributes
	attributes:     [dynamic]Attribute,

	// String table
	intern:         ^strings.Intern,
}

File_Type :: enum u8 {
	unknown               = 0,

	// Handled EXR file types, per the v2.0 spec.
	single_part_scan_line = 1,
	single_part_tiled     = 2,
	multi_part_image      = 3,
	single_part_deep_data = 4,
	multi_part_deep_data  = 5,
}

Pixel_Type :: enum i32le {
	u32le = 0,
	f16le = 1,
	f32le = 2,
}

Channel_Info :: struct #packed {
	pixel_type: Pixel_Type,
	p_linear:   u8, // Possible values are 0 or 1.
	reserved:   [3]u8,
	x_sampling: i32le,
	y_sampling: i32le,
}
#assert(size_of(Channel_Info) == 16);

Channel :: struct {
	name: string,
	using info: Channel_Info,
	data: []u8, // Slice into Image data.
	skip: bool,
	pixel_size: u8,
}

Attribute_Header :: struct {
	name:  string,
	type:  string,
	size:  i32le,
}

Attribute :: struct {
	using hdr: Attribute_Header,
	offset:    i64, // Offset of data
	data:      any,
}

Compression_Type :: enum u8 {
	None  = 0,
	RLE   = 1,
	ZIPS  = 2,
	ZIP   = 3,
	PIZ   = 4,
	PXR24 = 5,
	B44   = 6,
	B44A  = 7,
}

Line_Order :: enum u8 {
	Increasing_Y = 0,
	Decreasing_Y = 1,
	Random_Y     = 2,
}

Box2i :: struct {
	x_min: i32le,
	y_min: i32le,
	x_max: i32le,
	y_max: i32le,
}
#assert(size_of(Box2i) == 16);

Box2f :: struct {
	x_min: f32le,
	y_min: f32le,
	x_max: f32le,
	y_max: f32le,
}
#assert(size_of(Box2f) == 16);

// TODO: Use math.linalg vectors?
V2f :: struct {
	x: f32le,
	y: f32le,
}
#assert(size_of(V2f) == 8);

V2i :: struct {
	x: i32le,
	y: i32le,
}
#assert(size_of(V2i) == 8);

V3f :: struct #packed {
	x: f32le,
	y: f32le,
	z: f32le,
}
#assert(size_of(V3f) == 12);

V3i :: struct #packed {
	x: i32le,
	y: i32le,
	z: i32le,
}
#assert(size_of(V3i) == 12);

V4f :: struct #packed {
	x: f32le,
	y: f32le,
	z: f32le,
	w: f32le,
}
#assert(size_of(V4f) == 16);

Timecode :: struct {
	time_and_flags: i32le,
	user_data: i32le,
}
#assert(size_of(Timecode) == 8);

Rational :: struct {
	numerator:   i32le,
	denominator: u32le,
}
#assert(size_of(Rational) == 8);

Matrix_3x3 :: struct #packed {
	x: V3f,
	y: V3f,
	z: V3f,
}
#assert(size_of(Matrix_3x3) == 36);

Matrix_4x4 :: struct #packed {
	x: V4f,
	y: V4f,
	z: V4f,
	w: V4f,
}
#assert(size_of(Matrix_4x4) == 64);

// TODO: See about sharing the Chromacity structs with PNG.
CIE_1931_Raw :: struct #packed {
	x: f32le,
	y: f32le,
}
#assert(size_of(CIE_1931_Raw) == 8);

CIE_1931 :: struct #packed {
	x: f32,
	y: f32,
}
#assert(size_of(CIE_1931) == 8);

Chromacities_Raw :: struct #packed {
   r: CIE_1931_Raw,
   g: CIE_1931_Raw,
   b: CIE_1931_Raw,
   w: CIE_1931_Raw,   
}
#assert(size_of(Chromacities_Raw) == 32);

Chromacities :: struct #packed {
   w: CIE_1931,
   r: CIE_1931,
   g: CIE_1931,
   b: CIE_1931,
}
#assert(size_of(Chromacities) == 32);

Key_Code :: struct #packed {
	film_manufacturer_code: i32le,
	film_type: i32le,
	prefix: i32le,
	count: i32le,
	perf_offset: i32le,
	perfs_per_frame: i32le,
	perfs_per_count: i32le,
}
#assert(size_of(Key_Code) == 28)

Environment_Map :: enum u8 {
	Lat_Long = 0,
	Cube     = 1,
}

Tile_Desc :: struct #packed {
	x_size: u32le,
	y_size: u32le,
	mode  : Tile_Modes,
}
#assert(size_of(Tile_Desc) == 9);

Tile_Mode :: enum u8 {
	MIP_MAP  = 0, // 1`<< 0 = 1
	RIP_MAP  = 1, // 1 << 1 = 2

	ROUND_UP = 4, // 1 << 4 = 16
}
Tile_Modes :: bit_set[Tile_Mode; u8];

read_zstring :: proc(ctx: ^Context, intern: ^strings.Intern, flags: Version_Flags) -> (res: string, err: Error) {
	max_len := 31; // Excluding terminator.
	if .long_names in flags {
		max_len = 255;
	}

	temp := make([]u8, max_len, context.temp_allocator);

	i := 0;
	for {
		c, io_error := compress.read_data(ctx, u8);
		if io_error != .None {
			return {}, E_General.Stream_Too_Short;
		}

		temp[i] = c; i += 1;

		if c == 0 {
			break;
		}

		if i > max_len {
			return {}, E_EXR.Name_Too_Long;
		}
	}
	interned := strings.intern_get(intern, string(temp[:i-1]));

	return interned, nil;
}

read_channel_list :: proc(ctx: ^Context, intern: ^strings.Intern, flags: Version_Flags, info: ^Info, length: i32le) -> (err: Error) {
	ch:     Channel;
	total:  int;
	io_err: io.Error;


	for total < int(length) {
		ch.name, err = read_zstring(ctx, intern, flags);
		if err != nil {
			return err;
		}
		total += len(ch.name) + 1;
		/*
			If ch.name = 0, we've reached the end of the channel list.
			Total should now be attr_hdr.size (length).
		*/
		if len(ch.name) == 0 {
			if total == int(length) {
				break;
			}
			/*
				A zero-length channel name when we've not reached the size of the channel list is a bug in the file.
			*/
			return E_EXR.Corrupt;
		}

		ch.info, io_err = compress.read_data(ctx, Channel_Info);
		if io_err != .None {
			return E_General.Stream_Too_Short;
		}
		total += size_of(Channel_Info);

		switch ch.info.pixel_type {
		case .u32le, .f32le:
			ch.pixel_size = 4;
		case .f16le:
			ch.pixel_size = 2;
		}

		info.channels[ch.name] = ch;
		append(&info.channel_order, ch.name);
	}

	return nil;
}

append_attribute :: proc(ctx: ^Context, info: ^Info, attr_hdr: Attribute_Header, data: any) {
	attr := Attribute{};
	io_err: io.Error;

	attr.hdr = attr_hdr;
	attr.offset, io_err = ctx.input->impl_seek(0, .Current);
	attr.data = data;

	append(&info.attributes, attr);
}

read_attribute_header :: proc(ctx: ^Context, intern: ^strings.Intern, flags: Version_Flags) -> (res: Attribute_Header, err: Error) {

	res.name, err = read_zstring(ctx, intern, flags);
	if err != nil {
		destroy(res);
		return {}, err;
	}
	if len(res.name) == 0 {
		return {}, E_EXR.End_of_Header;
	}

	res.type, err = read_zstring(ctx, intern, flags);
	if err != nil {
		destroy(res);
		return {}, err;
	}

	io_err: io.Error;
	res.size, io_err = compress.read_data(ctx, i32le);

	return res, err;
}

load_from_slice__extended :: proc(slice: []u8, options := Options{}, allocator := context.allocator) -> (img: ^Image, err: Error) {
	r := bytes.Reader{};
	bytes.reader_init(&r, slice);
	stream := bytes.reader_to_stream(&r);

	/*
		TODO: Add a flag to tell the PNG loader that the stream is backed by a slice.
		This way the stream reader could avoid the copy into the temp memory returned by it,
		and instead return a slice into the original memory that's already owned by the caller.
	*/
	img, err = load__extended(stream, options, allocator);

	return img, err;
}

load_from_file__extended :: proc(filename: string, options := Options{}, allocator := context.allocator) -> (img: ^Image, err: Error) {
	data, ok := os.read_entire_file(filename, allocator);
	defer delete(data);

	if ok {
		img, err = load__extended(data, options, allocator);
		return;
	} else {
		img = new(Image);
		return img, E_General.File_Not_Found;
	}
}

load_from_stream__extended :: proc(stream: io.Stream, options := Options{}, allocator := context.allocator) -> (img: ^Image, err: Error) {
	options := options;
	if .info in options {
		options |= {.return_metadata, .do_not_decompress_image};
		options -= {.info};
	}

	if .alpha_drop_if_present in options && .alpha_add_if_missing in options {
		return {}, E_General.Incompatible_Options;
	}

	if img == nil {
		img = new(Image);
	}

	intern := new(strings.Intern);
	strings.intern_init(intern);

	info := new(Info);
	info.intern = intern;
	img.sidecar = info;

	ctx := compress.Context{
		input = stream,
	};

	signature, io_error := compress.read_data(&ctx, Signature);

	if io_error != .None || signature != .EXR {
		return img, E_EXR.Invalid_Signature;
	}

	version: Version;
	version, io_error = compress.read_data(&ctx, Version);
	if io_error != .None {
		return img, E_EXR.Corrupt;
	}

	if version.openexr_version > EXR_FILE_VERSION_SUPPORTED {
		return img, E_EXR.Version_Unsupported;
	}

	valid: bool;
	if .deep_data not_in version.flags && .multi_part not_in version.flags {
		// Single part scan line or tiled.
		valid = true;
		if .single_part_tiled in version.flags {
			info.type = .single_part_tiled;
		} else {
			info.type = .single_part_scan_line;
		}
	} else if .multi_part in version.flags && .deep_data not_in version.flags && .single_part_tiled not_in version.flags {
		valid = true;
		info.type = .multi_part_image;
	} else if .deep_data in version.flags && .single_part_tiled not_in version.flags {
		valid = true;
		if .multi_part in version.flags {
			info.type = .multi_part_deep_data;
		} else {
			info.type = .single_part_deep_data;
		}
	} else {
		valid = false;
		info.type = .unknown;
	}

	if !valid {
		return img, E_EXR.Invalid_Feature_Combo;
	}

	/*
		Read EXR header, which consists a number of `Attribute`s.


		TODO: Make procs that read (or skip) attributes of various types and
			  optionally append them to info.attributes.

	*/

	io_err: io.Error;
	offset: i64;

	chunk_count     := 0;
	seen_chunkCount := false;

	tiledesc        := Tile_Desc{};
	seen_tiledesc   := false;

	header_zero     := 0;
	end_of_headers  := false;

	part_number     := 0;
	attr_hdr := Attribute_Header{};

	for {
		if attr_hdr.size == 0 {
			fmt.printf("\nParsing headers for part #%v\n", part_number);
		}
		attr_hdr, err = read_attribute_header(&ctx, info.intern, version.flags);

		if attr_hdr.size == 0 || err == E_EXR.End_of_Header {
			if .multi_part not_in version.flags {
				end_of_headers = true;
			}
			header_zero += 1;
			if header_zero == 2 {
				end_of_headers = true;
			}
			err = nil;

			if !end_of_headers {
				part_number += 1;
			}
		} else {
			header_zero = 0;
		}

		if end_of_headers {
			offset, io_err = ctx.input->impl_seek(0, .Current);
			fmt.printf("End of attributes at 0x%x.\n", offset);
			err = nil;
			break;
		}

		if attr_hdr.size > 0 {
			printf("Parsing attribute '%v' of type '%v' and size %v:\n", attr_hdr.name, attr_hdr.type, attr_hdr.size);
		}

		switch(attr_hdr.type) {
		case "chlist":
			if attr_hdr.name != "channels" {
				return img, E_EXR.Invalid_Attribute;
			}
			/*
				Channel list follows.
			*/
			err = read_channel_list(&ctx, intern, version.flags, info, attr_hdr.size);
			if err != nil{
				return img, err;
			}

			img.channels = 0;

			for _, ch in info.channels {
				fmt.printf("\tChannel '%v' of pixel type '%v', sampling %v:%v\n", ch.name, ch.pixel_type, ch.x_sampling, ch.y_sampling);
				switch(ch.pixel_type) {
				case .f16le:
					img.depth += 16;
				case .f32le, .u32le:
					img.depth += 32;
				}
				img.channels += 1;
			}

		case "tiledesc":
			if attr_hdr.name != "tiles" {
				return img, E_EXR.Invalid_Attribute;
			}
			tiledesc, io_err = compress.read_data(&ctx, Tile_Desc);
			if io_err != .None {
				return img, E_EXR.Corrupt;
			}
			seen_tiledesc = true;

			printf("\tTileDesc: %v\n", tiledesc);

		case "compression":
			if attr_hdr.name != "compression" {
				return img, E_EXR.Invalid_Attribute;
			}
			info.compression, io_err = compress.read_data(&ctx, Compression_Type);
			if io_err != .None {
				return img, E_EXR.Corrupt;
			}

			printf("\tCompression method: %v\n", info.compression);

		case "chromaticities":
			if attr_hdr.name != "chromaticities" {
				return img, E_EXR.Invalid_Attribute;
			}
			chrm_r: Chromacities_Raw;
			chrm_r, io_err = compress.read_data(&ctx, Chromacities_Raw);
			if io_err != .None {
				return img, E_EXR.Corrupt;
			}

			info.chromacities = Chromacities{
				r = CIE_1931{f32(chrm_r.r.x), f32(chrm_r.r.y)},
				g = CIE_1931{f32(chrm_r.g.x), f32(chrm_r.g.y)},
				b = CIE_1931{f32(chrm_r.b.x), f32(chrm_r.b.y)},
				w = CIE_1931{f32(chrm_r.w.x), f32(chrm_r.w.y)},
			};

			printf("\tChromacities: %v\n", info.chromacities);
			append_attribute(&ctx, info, attr_hdr, info.chromacities);

		case "lineOrder":
			if attr_hdr.name != "lineOrder" {
				return img, E_EXR.Invalid_Attribute;
			}
			info.line_order, io_err = compress.read_data(&ctx, Line_Order);
			if io_err != .None {
				return img, E_EXR.Corrupt;
			}

			printf("\tLine Order: %v\n", info.line_order);

		case "int":
			i: i32le;
			i, io_err = compress.read_data(&ctx, i32le);
			if io_err != .None {
				return img, E_EXR.Corrupt;
			}
			printf("\tValue: %v\n", i);
			append_attribute(&ctx, info, attr_hdr, i);

			if attr_hdr.name == "chunkCount" {
				chunk_count = int(i);
				seen_chunkCount = true;
			}

		case "float":
			f: f32le;
			f, io_err = compress.read_data(&ctx, f32le);
			if io_err != .None {
				return img, E_EXR.Corrupt;
			}
			printf("\tValue: %v\n", f);
			append_attribute(&ctx, info, attr_hdr, f);

		case "v2f":
			v: V2f;
			v, io_err = compress.read_data(&ctx, V2f);
			if io_err != .None {
				return img, E_EXR.Corrupt;
			}
			printf("\tValue: %v\n", v);
			append_attribute(&ctx, info, attr_hdr, v);

		case "string":
			b := make([]u8, attr_hdr.size, context.temp_allocator);
			r, e1 := io.to_reader(ctx.input);
			_, e2 := io.read(r, b);
			if !e1 || e2 != .None {
				return img, E_EXR.Corrupt;
			}
			s := string(b);

			printf("\tValue: %v\n", s);
			append_attribute(&ctx, info, attr_hdr, s);

		case "box2i":
			window: Box2i;
			window, io_err = compress.read_data(&ctx, Box2i);
			if io_err != .None {
				return img, E_EXR.Corrupt;
			}

			switch(attr_hdr.name) {
			case "dataWindow":
				info.data_window = window;

				img.width  = int(window.x_max - window.x_min + 1);
				img.height = int(window.y_max - window.y_min + 1);
			case "displayWindow":
				info.display_window = window;
			case:
				append_attribute(&ctx, info, attr_hdr, window);
			}

			printf("\tWindow: %v\n", window);

		case "preview":
			printf("\tSkipped.\n");
			_, io_err = ctx.input->impl_seek(i64(attr_hdr.size), .Current);
			if io_err != .None {
				return img, E_EXR.Corrupt;
			}


		case:
			if attr_hdr.size > 0 {
				printf("\tUnhandled Attribute Type.\n");
				_, io_err = ctx.input->impl_seek(i64(attr_hdr.size), .Current);
				if io_err != .None {
					return img, E_EXR.Corrupt;
				}
			}
		}
	}

	if len(info.channels) == 0 {
		return img, E_EXR.Corrupt;
	}
	if .single_part_tiled in version.flags && !seen_tiledesc {
		return img, E_EXR.Missing_TileDesc_Attribute;
	}

	/*
		Early out if we just want the metadata.
	*/
	if .do_not_decompress_image in options {
		return img, nil;
	}
	/*
		Offset table follows:
	*/

	if !seen_chunkCount {
		if .multi_part in version.flags || .deep_data in version.flags {
			/*
				Multi-part and Deep Data files MUST have a `chunkCount` attribute.
			*/
			return img, E_EXR.Missing_Chunk_Count_Attribute;
		} else {
			/*
				We need to compute the number of chunks from `dataWindow`, `tileDesc` and the compression format.
			*/

			scanlines := int(info.data_window.y_max - info.data_window.y_min + 1);
			width     := int(info.data_window.x_max - info.data_window.x_min + 1);

			#partial switch(info.compression) {
			case .ZIP:
				if .single_part_tiled not_in version.flags {
					chunk_count = scanlines >> 4;
					if scanlines % 16 > 0 {
						chunk_count += 1;
					}
				} else {
					chunk_count = num_tiles(width, scanlines, tiledesc);
					fmt.printf("num tiles: %v\n", chunk_count);
				}
			case .ZIPS:
				chunk_count = scanlines;
			case:
				return img, E_EXR.Compression_Unsupported;
			}

		}
	}

	fmt.printf("Expecting %v chunk offsets.\n", chunk_count);
	for i := 0; i < chunk_count; i += 1 {
		offset: u64le;
		offset, io_err = compress.read_data(&ctx, u64le);
		if io_err != .None {
			return img, E_EXR.Corrupt;
		}
		// fmt.printf("Offset %04d: %v (%08x)\n", i, offset, offset);
	}

	/*
		Chunk data should follow.
	*/

	pixel_buffer_size := image.compute_buffer_size(img.width, img.height, 1, img.depth);
	fmt.printf("We need %v bytes for the output buffer.\n", pixel_buffer_size);
	bytes.buffer_init_allocator(&img.pixels, pixel_buffer_size, pixel_buffer_size);

	output := bytes.buffer_to_bytes(&img.pixels);

	ch_off := 0;
	/*
		We use the channel_order list instead of the map to make sure the slices are
		assigned in the order the header told us the channels are in.
	*/
	for name in info.channel_order {
		ch := &info.channels[name];
		// TODO: Take into account x:y sampling.
		length := img.width * img.height * int(ch.pixel_size);
		if !ch.skip {
			ch.data = output[ch_off:ch_off+length];
		}

		fmt.printf("%v) offset: %v, length: %v, ps: %v\n", ch.name, ch_off, length, ch.pixel_size);
		ch_off += length;
	}
	assert (ch_off == pixel_buffer_size);

	#partial switch(info.compression) {
	case .ZIP, .ZIPS:
		if .single_part_tiled not_in version.flags {
			err = zip_decompress(img, &ctx, chunk_count, version.flags);
		} else {
			err = zip_decompress_tiled(img, &ctx, chunk_count, version.flags, tiledesc);
		}
		if err != nil {
			return img, err;
		}
	case:
		return img, E_EXR.Compression_Unsupported;
	}	

	return img, nil;
}

zip_decompress :: proc(img: ^Image, ctx: ^Context, chunk_count: int, flags: Version_Flags) -> (err: Error) {
	io_err: io.Error;

	info := img.sidecar.(^Info);
	num_channels := len(info.channels);

	written := 0;
	y_min := info.data_window.y_min;

	Component :: struct{
		data:   []u8,
		skip:   bool,
		size:   u8, // Per element/pixel
		stride: int,
	};
	components := make([dynamic]Component, num_channels);
	defer delete(components);

	for _, ch in info.channels {
		component := Component{
			data = ch.data,
			skip = ch.skip,
			size = ch.pixel_size,
			// For tiles this has to be recalculated each tile, as width can change on the edges.
			stride = int(ch.pixel_size) * img.width,
		};
		append(&components, component);
	}

	r, e1 := io.to_reader(ctx.input);
	if !e1 {
		return E_EXR.Corrupt;
	}

	for ci := 0; ci < chunk_count; ci += 1 {
		part_number: i32le;
		if .multi_part in flags {
			part_number, io_err = compress.read_data(ctx, i32le);
			if io_err != .None {
				return E_EXR.Corrupt;
			}
			fmt.printf("Part: %v\n", part_number);
		}

		y_coord: i32le;
		y_coord, io_err = compress.read_data(ctx, i32le);
		if io_err != .None {
			return E_EXR.Corrupt;
		}
		// fmt.printf("Y: %v | ", y_coord);

		chunk_size: i32le;
		chunk_size, io_err = compress.read_data(ctx, i32le);
		if io_err != .None {
			return E_EXR.Corrupt;
		}

		// ZLIB could read directly from the stream if we wanted to.
		b := make([]u8, i64(chunk_size), context.temp_allocator);
		_, e2 := io.read(r, b);
		if e2 != .None {
			return E_EXR.Corrupt;	
		}

		buf: bytes.Buffer;
		zlib_err := zlib.inflate(b, &buf);
		defer bytes.buffer_destroy(&buf);

		if zlib_err != nil {
			return E_EXR.Corrupt;
		}
		fmt.printf(".");

		raw := bytes.buffer_to_bytes(&buf);
		length := len(raw);

		p := u16(raw[0]);
		for j := 1; j < length; j += 1 {
			p += u16(raw[j]);
			p -= u16(128);
			raw[j] = u8(p);
		}

		half := (length + 1) / 2;
		deinterleaved := soa_zip(odd=raw[:length-half], even=raw[half:]);

		/*
			TODO: We could make a buffer once at the start of the proc if we calculate the max chunk size.
		*/

		temp: bytes.Buffer;
		bytes.buffer_init_allocator(&temp, length, length, context.allocator);
		defer bytes.buffer_destroy(&temp);
		t := bytes.buffer_to_bytes(&temp);

		i := 0;
		for v in deinterleaved {
			t[i]     = v.odd;
			t[i + 1] = v.even;
			i += 2;
		}

		offset := 0;
		for len(t) > 0 {
			for comp in components {
				/*
					This offset calculation should work for INCREASING_Y, DECREASING_Y and RANDOM_Y ordering.
				*/
				offset = image.compute_buffer_size(img.width, int(y_coord - y_min), int(comp.size), 8);

				if !comp.skip {
					copy(comp.data[offset:], t[:comp.stride]);
				}
				t = t[comp.stride:];
				written += comp.stride;
			}
			/*
				INCREASING_Y, DECREASING_Y and RANDOM_Y is about the order chunks appear in.
				Scanlines within a chunk are in increasing order, so we can just do this.
			*/
			y_coord += 1;
		}
	}

	assert(written == len(img.pixels.buf));
	fmt.println("\nDecompressed image.");

	return nil;
}

zip_decompress_tiled :: proc(img: ^Image, ctx: ^Context, chunk_count: int, flags: Version_Flags, tiledesc: Tile_Desc) -> (err: Error) {
	io_err: io.Error;

	info := img.sidecar.(^Info);

	fmt.printf("TD: %v\n", tiledesc);
	fmt.printf("Depth: %v\n", img.depth);

	output := bytes.buffer_to_bytes(&img.pixels);

	written := 0;
	y_min   := int(info.data_window.y_min);

	r, e1 := io.to_reader(ctx.input);
	if !e1 {
		return E_EXR.Corrupt;
	}

	Tile_Coord :: struct {
		x_coord: i32le,
		y_coord: i32le,
		x_level: i32le,
		y_level: i32le,
	};
	#assert(size_of(Tile_Coord) == 16);

	for ci := 0; ci < chunk_count; ci += 1 {
		part_number: i32le;
		if .multi_part in flags {
			part_number, io_err = compress.read_data(ctx, i32le);
			if io_err != .None {
				return E_EXR.Corrupt;
			}
			fmt.printf("Part: %v\n", part_number);
		}

		coord: Tile_Coord;
		coord, io_err = compress.read_data(ctx, Tile_Coord);
		if io_err != .None {
			return E_EXR.Corrupt;
		}

		chunk_size: i32le;
		chunk_size, io_err = compress.read_data(ctx, i32le);
		if io_err != .None {
			return E_EXR.Corrupt;
		}

		// ZLIB could read directly from the stream if we wanted to.
		b := make([]u8, i64(chunk_size), context.temp_allocator);
		_, e2 := io.read(r, b);
		if e2 != .None {
			return E_EXR.Corrupt;	
		}

		// img.width  = 128;
		// img.height = 128 * 5;
		if coord.x_coord != 0 || coord.x_level > 0 { // || coord.y_coord > 4 {
			//return nil;
			continue;
		}

		fmt.printf("Tile: %v\n", coord);

		buf: bytes.Buffer;
		zlib_err := zlib.inflate(b, &buf);
		defer bytes.buffer_destroy(&buf);

		if zlib_err != nil {
			return E_EXR.Corrupt;
		}

		raw := bytes.buffer_to_bytes(&buf);
		length := len(raw);

		tile_bounds := [4]int{
			int(coord.x_coord),
			int(coord.y_coord),
			int(coord.x_coord) + 1,
			int(coord.y_coord) + 1,
		};
		tile_bounds.xz *= int(tiledesc.x_size);
		tile_bounds.yw *= int(tiledesc.y_size);

		if tile_bounds.z > img.width {
			tile_bounds.z = tile_bounds.x + img.width  % int(tiledesc.x_size);
		}
		if tile_bounds.w > img.height {
			tile_bounds.w = tile_bounds.y + img.height % int(tiledesc.y_size);
		}

		fmt.printf("Tile Bounds: %v\n", tile_bounds);

		// This should work for INCREASING_Y, DECREASING_Y and RANDOM_Y scanline ordering.

		row_stride    := image.compute_buffer_size(img.width,     1, 1, img.depth);
		tile_width    := tile_bounds.z - tile_bounds.x;
		tile_stride   := image.compute_buffer_size(tile_width,    1, 1, img.depth);
		column_offset := image.compute_buffer_size(tile_bounds.x, 1, 1, img.depth);

		y := (tile_bounds.y - y_min);

		offset := y * row_stride + column_offset;
		fmt.printf("Column Offset: %v | Tile Width: %v | Tile Stride: %v | Row Stride: %v | Offset: %v\n", column_offset, tile_width, tile_stride, row_stride, offset);

		p := u16(raw[0]);
		for j := 1; j < length; j += 1 {
			p += u16(raw[j]);
			p -= u16(128);
			raw[j] = u8(p);
		}

		half := (length + 1) / 2;
		deinterleaved := soa_zip(odd=raw[:length-half], even=raw[half:]);

		c := 0;

		for v in deinterleaved {
			output[offset + c    ] = v.odd;
			output[offset + c + 1] = v.even;
			c += 2;
			if c >= tile_stride {
				c = 0;
				y += 1;
				offset = y * row_stride + column_offset;
			}
		}
		if length & 1 == 1 {
			// Handle odd number of bytes.
			output[offset] = raw[length - 1];	
		}

		written += length;
	}

	fmt.println("Decompressed image.");

	return nil;
}


/*
	RGB(A) interfaces follow
*/

load_from_slice :: proc(slice: []u8, options := Options{}, allocator := context.allocator) -> (img: ^Image, err: Error) {
	r := bytes.Reader{};
	bytes.reader_init(&r, slice);
	stream := bytes.reader_to_stream(&r);

	/*
		TODO: Add a flag to tell the PNG loader that the stream is backed by a slice.
		This way the stream reader could avoid the copy into the temp memory returned by it,
		and instead return a slice into the original memory that's already owned by the caller.
	*/
	img, err = load(stream, options, allocator);

	return img, err;
}

load_from_file :: proc(filename: string, options := Options{}, allocator := context.allocator) -> (img: ^Image, err: Error) {
	data, ok := os.read_entire_file(filename, allocator);
	defer delete(data);

	if ok {
		img, err = load(data, options, allocator);
		return;
	} else {
		img = new(Image);
		return img, E_General.File_Not_Found;
	}
}

load_from_stream :: proc(stream: io.Stream, options := Options{}, allocator := context.allocator) -> (img: ^Image, err: Error) {

	fmt.printf("Loading as RGB(A)...\n");

	/*
		TODO: Give the extended API an ability to load specific channels and return an error if they're not present.
		That way we can ask for just R, RG, RGB, RGBA, Luma/Chroma, or other channel combinations that we can
		return as an RGB(A) image.
	*/
	img, err = load__extended(stream, options, allocator);
	if .info in options || .do_not_decompress_image in options {
		/*
			There's no image data for us to reinterleave here.
		*/
		return;
	}

	if err != nil {
		/*
			An error occcured, let's pass back to the caller.
		*/
		return;
	}

	info := img.sidecar.(^Info);
	channels := info.channels;

	out: any;
	buf: bytes.Buffer;

	fmt.println();
	if "R" in channels || "G" in channels || "B" in channels {
		have_f16: bool;
		have_f32: bool;
		have_u32: bool;

		pixel_type := Pixel_Type(Pixel_Type.f16le);
		channel_count := 0;

		have_R: bool;
		have_G: bool;
		have_B: bool;
		have_A: bool;

		for ch in channels {
			switch(ch) {
			case "R":
				have_R = true;
			case "G":
				have_G = true;
			case "B":
				have_B = true;
			case "A":
				have_A = true;
			case:
				// Skip channels that won't contribute to the RGB(A) output.
				continue;
			}

			channel_count += 1;
			pt := channels[ch].pixel_type;
			switch(pt) {
			case .u32le:
				have_u32 = true;
				pixel_type = pt;
				if have_f16 || have_f32 {
					// We don't mix integer and float channels, at least for now.
					return img, E_EXR.Mixed_Integer_And_Float_Channels_Not_Supported;
				}
				img.depth = 32;
			case .f16le:
				have_f16 = true;
				if have_u32 {
					// We don't mix integer and float channels, at least for now.
					return img, E_EXR.Mixed_Integer_And_Float_Channels_Not_Supported;
				}
				if !have_f32 {
					// If we have at least one f32 channel, we'll return an f32 image.
					pixel_type = pt;
					img.depth = 16;
				}
			case .f32le:
				have_f32 = true;
				if have_u32 {
					// We don't mix integer and float channels, at least for now.
					return img, E_EXR.Mixed_Integer_And_Float_Channels_Not_Supported;
				}
				// If we have at least one f32 channel, we'll return an f32 image.
				pixel_type = pt;
				img.depth = 32;
			}
		}

		fmt.printf("We have a %v image of type %v\n", channel_count, pixel_type);

		pixel_buffer_size := image.compute_buffer_size(img.width, img.height, channel_count, img.depth);
		fmt.printf("We need %v bytes for the output buffer.\n", pixel_buffer_size);
		
		bytes.buffer_init_allocator(&buf, pixel_buffer_size, pixel_buffer_size);

		switch(pixel_type) {
		case .u32le:
			pix := mem.slice_data_cast([]u32, buf.buf[:]);
			assert(len(pix) == img.width * img.height * channel_count);
			out = pix;
		case .f16le:
			pix := mem.slice_data_cast([]f16, buf.buf[:]);
			assert(len(pix) == img.width * img.height * channel_count);
			out = pix;
		case .f32le:
			pix := mem.slice_data_cast([]f32, buf.buf[:]);
			assert(len(pix) == img.width * img.height * channel_count);
			out = pix;
		}

		if have_R {
			pixel_type = channels["R"].pixel_type;
		}

		bytes.buffer_destroy(&img.pixels);
		img.pixels = buf;
	} else {
		// We don't handle LumaChroma and stuff yet. Return image as-is for now.
		// We'll make an error for this or add support soon.
		return;
	}

	return;
}

/*
	Extended interface that give you access to all the options,
	and which return image contents as individual slices.
*/
load__extended :: proc{load_from_file__extended, load_from_slice__extended, load_from_stream__extended};

/*
	RGB(A) interface that'll use the extended interface to probe for
	and extract RGB(A), single channel or Luma/Chroma images and return
	the contents as a single HDR RGB(A) image buffer.
*/
load :: proc{load_from_file, load_from_slice, load_from_stream};
