package openexr

import "core:image"
// import "core:compress/zlib"
// import coretime "core:time"
// import "core:strings"
import "core:bytes"
import "core:fmt"
import "core:mem"
import "core:math"
import "core:intrinsics"

/*
	These are a few useful utility functions to work with OpenEXR images.
*/

/*
	Cleanup of image-specific data.
	There are other helpers for cleanup of PNG-specific data.
	Those are named *_destroy, where * is the name of the helper.
*/

destroy_image :: proc(img: ^Image) {
	fmt.println("Destroying Image.");
	if img == nil {
		/*
			Nothing to do.
			Load must've returned with an error.
		*/
		return;
	}

	bytes.buffer_destroy(&img.pixels);

	// if v, ok := img.sidecar.(^Info); ok {
	//  delete the channel map and channel order array
	// 	strings.intern_destroy(v.intern);
	// 	free(v.intern);
	// 	free(v);
	// }

	free(img);
}

destroy_attr_hdr :: proc(attr: Attribute_Header) {
	// Not needed. Strings are interned.
}

destroy :: proc{destroy_image, destroy_attr_hdr};

remap :: proc(img: ^Image) {

	if len(img.pixels.buf[:]) == 0 do return;

	do_clamp :: proc(v, min, max: $T) -> (res: T) {
		c: = f64(v);
		if c < 0.0 do c = 0.0;
		if c > 1.0 do c = 1.0;

		return T(c * 255.0);

		// return T(math.remap(c, 0.0, 1.0, 0.0, 255.0));
	}

	floats := mem.slice_data_cast([]f16le, img.pixels.buf[:]);

	h := [2]f16le{};
	for p in floats {
		if !math.is_inf(f16(p)) {
			h[0] = p < h[0] ? p : h[0];
			h[1] = p > h[1] ? p : h[1];
		}
	}
	fmt.printf("min: %v, max: %v, range: %v\n", h[0], h[1], h[1] - h[0]);

	output: bytes.Buffer;
	img.depth    = 8;
	img.channels = 3;

	fmt.printf("x: %v, y: %v, c: %v: d: %v\n", img.width, img.height, img.channels, img.depth);

	pixel_buffer_size := image.compute_buffer_size(img.width, img.height, img.channels, img.depth);
	bytes.buffer_init_allocator(&output, pixel_buffer_size, pixel_buffer_size);
	fmt.printf("Created buffer of size %v for remapped image.\n", pixel_buffer_size);

	out := bytes.buffer_to_bytes(&output);
	idx := 0;

	for y := 0; y < img.height; y += 1 {
		// idx = (y * img.width * img.channels) + 3;
		// for x := 0; x < img.width; x += 1 {
		// 	c := clamp(floats[0], 0.0, 1.0) * 255.0;
		// 	out[idx] = u8(c); idx += img.channels;
		// 	floats = floats[1:];
		// }
		// fmt.printf("Y: %v\n", y);

		idx = (y * img.width * img.channels) + 2;
		for w := 0; w < img.width; w += 1 {
			c := do_clamp(floats[0], h[0], h[1]);
			out[idx] = u8(c); idx += img.channels;
			floats = floats[1:];
		}

		idx = (y * img.width * img.channels) + 1;
		for w := 0; w < img.width; w += 1 {
			c := do_clamp(floats[0], h[0], h[1]);
			out[idx] = u8(c); idx += img.channels;
			floats = floats[1:];
		}

		idx = (y * img.width * img.channels) + 0;
		for w := 0; w < img.width; w += 1 {
			c := do_clamp(floats[0], h[0], h[1]);
			out[idx] = u8(c); idx += img.channels;
			floats = floats[1:];
		}
	}
	fmt.printf("%v floats left.\n", len(floats));

	bytes.buffer_destroy(&img.pixels);
	img.pixels = output;

	if ok := write_image_as_ppm("out.ppm", img); ok {
		fmt.println("Saved decoded image.");
	} else {
		fmt.println("Error saving out.ppm.");
	// fmt.println(img);
	}

}


num_tiles :: proc(width, height: int, tiledesc: Tile_Desc) -> (tiles: int) {
	/*
		See page 10 of v2.0 of https://www.openexr.com/documentation/TechnicalIntroduction.pdf
	*/

	/* LEVEL 0 */
	w := f64(width);
	h := f64(height);

	tiles_x := math.ceil(w / f64(tiledesc.x_size));
	tiles_y := math.ceil(h / f64(tiledesc.y_size));

	tiles = int(tiles_x) * int(tiles_y);
	switch(tiledesc.mode) {
	case {}, {.ROUND_UP}:
		// Just the one level
		return;
	case {.MIP_MAP}, {.MIP_MAP, .ROUND_UP}:
		for w != 1 && h != 1 {
			fmt.printf("x: %v, y: %v, total: %v\n", w, h, tiles);
			if .ROUND_UP in tiledesc.mode {
				w = math.ceil(w / 2.0);
				h = math.ceil(h / 2.0);
			} else {
				w = max(math.floor(w / 2.0), 1);
				h = max(math.floor(h / 2.0), 1);
			}

			tiles_x = math.ceil(w / f64(tiledesc.x_size));
			tiles_y = math.ceil(h / f64(tiledesc.y_size));
			tiles += int(tiles_x) * int(tiles_y);
		}
		fmt.printf("x: %v, y: %v, total: %v\n", w, h, tiles);
	case {.RIP_MAP}, {.RIP_MAP, .ROUND_UP}:				

	}
	return;
}

need_endian_conversion :: proc($FT: typeid, $TT: typeid) -> (res: bool) {

	// true if platform endian
	f: bool;
	t: bool;

	when ODIN_ENDIAN == "little" {
		f = intrinsics.type_is_endian_platform(FT) || intrinsics.type_is_endian_little(FT);
		t = intrinsics.type_is_endian_platform(TT) || intrinsics.type_is_endian_little(TT);

		return f != t;
	} else {
		f = intrinsics.type_is_endian_platform(FT) || intrinsics.type_is_endian_big(FT);
		t = intrinsics.type_is_endian_platform(TT) || intrinsics.type_is_endian_big(TT);

		return f != t;
	}

	return;
}

make_buffer_of_type :: proc(count: int, $FT: typeid, $TT: typeid, from_buffer: []u8) -> (
	res: []TT, backing: ^bytes.Buffer, alloc: bool, err: bool) {

	backing = new(bytes.Buffer);

	if FT == TT {
		res = mem.slice_data_cast([]TT, from_buffer);
		bytes.buffer_init(backing, from_buffer);
		if len(res) != count {
			err = true;
		}
		return;
	}

	if len(from_buffer) > 0 {
		/*
			Check if we've been given enough input elements
		*/
		from := mem.slice_data_cast([]FT, from_buffer);
		if len(from) != count {
			err = true;
			return;
		}

		/*
			We can do a data cast if in-size == out-size and no endian conversion is needed.
		*/
		convert := need_endian_conversion(FT, TT);
		convert |= (size_of(TT) * count != len(from_buffer));

		if !convert {
			// It's just a data cast
			res = mem.slice_data_cast([]TT, from_buffer);
			bytes.buffer_init(backing, from_buffer);

			if len(res) != count {
				err = true;
			}
			return;
		} else {
			// Do endianness and/or size_of conversion
		}
	} else {
		// Create new buffer
	}

	return;
}