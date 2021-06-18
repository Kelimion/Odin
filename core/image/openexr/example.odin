//+ignore
package openexr

import "core:compress"
import "core:image"
//import "core:image/openexr"
import "core:bytes"
import "core:fmt"

// For PPM writer
import "core:mem"
import "core:os"

SINGLE :: true;
when !SINGLE {
	import "core:path/filepath"
}

process_file :: proc(info: os.File_Info, in_err: os.Errno) -> (err: os.Errno, skip_dir: bool) {
	options :=  context.user_data.(image.Options);
	load_err:	compress.Error;
	img:       ^image.Image;

	if !info.is_dir && info.name[len(info.name)-4:] == ".exr" {
		file :=  info.fullpath;

		fmt.printf("Checking OpenEXR file: %v\n", file);
		img, load_err = load(file, options);
		defer destroy(img);

		if load_err != nil {
			fmt.printf("Returned error: %v\n", load_err);
		} else {
			info := img.sidecar.(^Info);
			fmt.printf(
				"Image: %vx%vx%v, %v-bit (type: %v, compression: %v)\n",
				img.width, img.height, img.channels, img.depth,
				info.type, info.compression,
			);
			if !(.info in options || .do_not_decompress_image in options) {
				remap(img);
			}
		}
	}
	return;
}

main :: proc() {
	when false {
		when SINGLE {
			context.user_data = image.Options{};
			filename := "W:\\compress-odin\\test\\OpenEXR test suite\\TestImages\\WideColorGamut.exr";
			// filename = "W:\\compress-odin\\test\\OpenEXR test suite\\MultiResolution\\Bonita.exr";
			// filename = "W:\\compress-odin\\test\\OpenEXR test suite\\Beachball\\multipart.0001.exr";
			// filename = "W:\\compress-odin\\test\\OpenEXR test suite\\v2\\LowResLeftView\\composited.exr";

			file, _ := os.stat(filename);
			process_file(file, os.Errno{});
		} else {
			context.user_data = image.Options{.info};
			filepath.walk("W:\\compress-odin\\test\\OpenEXR test suite", process_file);
		}
	} else {
		fmt.println("Convert []f16le (x2) to []f32 (x2).");
		b := []u8{0, 60, 0, 60}; // f16{1.0, 1.0}

		res, backing, had_to_allocate, err := convert_buffer_of_type(2, f32, f16le, b);
		fmt.printf("res      : %v\n", res);
		fmt.printf("backing  : %v\n", backing);
		fmt.printf("allocated: %v\n", had_to_allocate);
		fmt.printf("err      : %v\n", err);

		if had_to_allocate { defer bytes.buffer_destroy(backing); }

		fmt.println("\nAllocate a new buffer with create_buffer_of_type.");
		res, backing, err = create_buffer_of_type(2, f32);
		fmt.printf("res      : %v\n", res);
		fmt.printf("backing  : %v\n", backing);
		fmt.printf("allocated: %v\n", had_to_allocate);
		fmt.printf("err      : %v\n", err);

		if had_to_allocate { defer bytes.buffer_destroy(backing); }

		fmt.println("\nAllocate a new buffer with convert_buffer_of_type by passing an empty buffer.");
		b = []u8{}; // Empty so that we allocate. From type is ignored.

		res, backing, had_to_allocate, err = convert_buffer_of_type(2, f32, f32, b);
		fmt.printf("res      : %v\n", res);
		fmt.printf("backing  : %v\n", backing);
		fmt.printf("allocated: %v\n", had_to_allocate);
		fmt.printf("err      : %v\n", err);

		if had_to_allocate { defer bytes.buffer_destroy(backing); }
	}
}

// Crappy PPM writer used during testing. Don't use in production.
write_image_as_ppm :: proc(filename: string, image: ^image.Image) -> (success: bool) {

	_bg :: proc(bg: Maybe([3]u16), x, y: int, high := true) -> (res: [3]u16) {
		if v, ok := bg.?; ok {
			res = v;
		} else {
			if high {
				l := u16(30 * 256 + 30);

				if (x & 4 == 0) ~ (y & 4 == 0) {
					res = [3]u16{l, 0, l};
				} else {
					res = [3]u16{l >> 1, 0, l >> 1};
				}
			} else {
				if (x & 4 == 0) ~ (y & 4 == 0) {
					res = [3]u16{30, 30, 30};
				} else {
					res = [3]u16{15, 15, 15};
				}
			}
		}
		return;
	}

	// profiler.timed_proc();
	using image;
	using os;

	flags: int = O_WRONLY|O_CREATE|O_TRUNC;

	img := image;

	// PBM 16-bit images are big endian
	when ODIN_ENDIAN == "little" {
		if img.depth == 16 {
			// The pixel components are in Big Endian. Let's byteswap back.
			input  := mem.slice_data_cast([]u16,   img.pixels.buf[:]);
			output := mem.slice_data_cast([]u16be, img.pixels.buf[:]);
			#no_bounds_check for v, i in input {
				output[i] = u16be(v);
			}
		}
	}

	pix := bytes.buffer_to_bytes(&img.pixels);

	if len(pix) == 0 || len(pix) < image.width * image.height * int(image.channels) {
		return false;
	}

	mode: int = 0;
	when ODIN_OS == "linux" || ODIN_OS == "darwin" {
		// NOTE(justasd): 644 (owner read, write; group read; others read)
		mode = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH;
	}

	fd, err := open(filename, flags, mode);
	if err != 0 {
		return false;
	}
	defer close(fd);

	write_string(fd,
		fmt.tprintf("P6\n%v %v\n%v\n", width, height, (1 << u64(depth) -1)),
	);

	if channels == 3 {
		// We don't handle transparency here...
		write_ptr(fd, raw_data(pix), len(pix));
	} else {
		bpp := depth == 16 ? 2 : 1;
		bytes_needed := width * height * 3 * bpp;

		op := bytes.Buffer{};
		bytes.buffer_init_allocator(&op, bytes_needed, bytes_needed);
		defer bytes.buffer_destroy(&op);

		if channels == 1 {
			if depth == 16 {
				assert(len(pix) == width * height * 2);
				p16 := mem.slice_data_cast([]u16, pix);
				o16 := mem.slice_data_cast([]u16, op.buf[:]);
				#no_bounds_check for len(p16) != 0 {
					r := u16(p16[0]);
					o16[0] = r;
					o16[1] = r;
					o16[2] = r;
					p16 = p16[1:];
					o16 = o16[3:];
				}
			} else {
				o := 0;
				for i := 0; i < len(pix); i += 1 {
					r := pix[i];
					op.buf[o  ] = r;
					op.buf[o+1] = r;
					op.buf[o+2] = r;
					o += 3;
				}
			}
			write_ptr(fd, raw_data(op.buf), len(op.buf));
		} else if channels == 2 {
			if depth == 16 {
				p16 := mem.slice_data_cast([]u16, pix);
				o16 := mem.slice_data_cast([]u16, op.buf[:]);

				bgcol := img.background;

				#no_bounds_check for len(p16) != 0 {
					r  := f64(u16(p16[0]));
					bg:   f64;
					if bgcol != nil {
						v := bgcol.([3]u16)[0];
						bg = f64(v);
					}
					a  := f64(u16(p16[1])) / 65535.0;
					l  := (a * r) + (1 - a) * bg;

					o16[0] = u16(l);
					o16[1] = u16(l);
					o16[2] = u16(l);

					p16 = p16[2:];
					o16 = o16[3:];
				}
			} else {
				o := 0;
				for i := 0; i < len(pix); i += 2 {
					r := pix[i]; a := pix[i+1]; a1 := f32(a) / 255.0;
					c := u8(f32(r) * a1);
					op.buf[o  ] = c;
					op.buf[o+1] = c;
					op.buf[o+2] = c;
					o += 3;
				}
			}
			write_ptr(fd, raw_data(op.buf), len(op.buf));
		} else if channels == 4 {
			if depth == 16 {
				p16 := mem.slice_data_cast([]u16be, pix);
				o16 := mem.slice_data_cast([]u16be, op.buf[:]);

				#no_bounds_check for len(p16) != 0 {

					bg := _bg(img.background, 0, 0);
					r     := f32(p16[0]);
					g     := f32(p16[1]);
					b     := f32(p16[2]);
					a     := f32(p16[3]) / 65535.0;

					lr  := (a * r) + (1 - a) * f32(bg[0]);
					lg  := (a * g) + (1 - a) * f32(bg[1]);
					lb  := (a * b) + (1 - a) * f32(bg[2]);

					o16[0] = u16be(lr);
					o16[1] = u16be(lg);
					o16[2] = u16be(lb);

					p16 = p16[4:];
					o16 = o16[3:];
				}
			} else {
				o := 0;

				for i := 0; i < len(pix); i += 4 {

					x := (i / 4)  % width;
					y := i / width / 4;

					_b := _bg(img.background, x, y, false);
					bgcol := [3]u8{u8(_b[0]), u8(_b[1]), u8(_b[2])};

					r := f32(pix[i]);
					g := f32(pix[i+1]);
					b := f32(pix[i+2]);
					a := f32(pix[i+3]) / 255.0;

					lr := u8(f32(r) * a + (1 - a) * f32(bgcol[0]));
					lg := u8(f32(g) * a + (1 - a) * f32(bgcol[1]));
					lb := u8(f32(b) * a + (1 - a) * f32(bgcol[2]));
					op.buf[o  ] = lr;
					op.buf[o+1] = lg;
					op.buf[o+2] = lb;
					o += 3;
				}
			}
			write_ptr(fd, raw_data(op.buf), len(op.buf));
		} else {
			return false;
		}
	}
	return true;
}
