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

destroy_image :: proc(img: ^image.Image) {
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

	floats := mem.slice_data_cast([]f16, img.pixels.buf[:]);

	h := [2]f16{};
	for p in floats {
		if !math.is_inf(f16(p)) {
			h[0] = p < h[0] ? p : h[0];
			h[1] = p > h[1] ? p : h[1];
		}
	}
	fmt.printf("min: %v, max: %v, range: %v\n", h[0], h[1], h[1] - h[0]);

	out: []u8;
	output: ^bytes.Buffer;
	err: bool;

	img.depth = 8;
	pixels   := img.width * img.height;
	elements := pixels * img.channels;

	out, output, err = bytes.buffer_create_of_type(elements, u8);

	fmt.printf("Created buffer of size %v for remapped image.\n", elements);

	for len(floats) > 0 {
		c := do_clamp(floats[0], h[0], h[1]);
		out[0] = u8(c); out = out[1:];
		floats = floats[1:];
	}

	fmt.printf("%v floats left.\n", len(floats));

	bytes.buffer_destroy(&img.pixels);
	img.pixels = output^;

	if ok := write_image_as_ppm("out.ppm", img); ok {
		fmt.println("Saved decoded image.");
	} else {
		fmt.println("Error saving out.ppm.");
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