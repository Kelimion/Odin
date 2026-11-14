package test_core_json

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "base:runtime"

Failing_Allocator :: struct {
	backing: runtime.Allocator,
	left:    int,
	once:    bool,
}

failing_allocator_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	f := (^Failing_Allocator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if f.left <= 0 {
			if f.once {
				f.left = max(int)
			}
			return nil, .Out_Of_Memory
		}
		f.left -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

failing_allocator :: proc(f: ^Failing_Allocator) -> runtime.Allocator {
	return {procedure = failing_allocator_proc, data = f}
}

@(test)
review_parse_sjson_root_error_frees_once :: proc(t: ^testing.T) {
	for src in ([]string{"a: 1\n,b: 2", "a: 1, b: [", "a: {b: 1} c"}) {
		v, err := json.parse_string(src, .SJSON)
		testing.expectf(t, err != nil && v == nil, "%q: %v, %v", src, v, err)
		json.destroy_value(v)
	}
}

@(test)
review_parse_unclosed_object_does_not_leak :: proc(t: ^testing.T) {
	for src in ([]string{`{"a":1`, `{"a":1]`, `{"a":{"b":"c"}`, `[{"a":"x"}`}) {
		v, err := json.parse_string(src, .JSON)
		testing.expectf(t, err != nil && v == nil, "%q: %v, %v", src, v, err)
		json.destroy_value(v)
	}
}

@(test)
review_parse_empty_key :: proc(t: ^testing.T) {
	for spec in ([]json.Specification{.JSON, .JSON5, .SJSON}) {
		v, err := json.parse_string(`{"":1,"a":2}`, spec)
		defer json.destroy_value(v)
		obj, is_obj := v.(json.Object)
		testing.expectf(t, err == nil && is_obj && len(obj) == 2 && values_equal(obj[""], json.Float(1)), "%v: %v, %v", spec, v, err)

		dup, dup_err := json.parse_string(`{"":1,"":2}`, spec)
		testing.expectf(t, dup_err == .Duplicate_Object_Key && dup == nil, "%v: %v, %v", spec, dup, dup_err)
		json.destroy_value(dup)
	}
}

@(test)
review_parse_out_of_memory :: proc(t: ^testing.T) {
	SOURCES := []string{
		`[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18]`,
		`[{"a":"x"},{"b":"y"},["z"]]`,
		`{"a":1,"b":2,"c":3,"d":4,"e":5,"f":6,"g":7,"h":8,"i":9,"j":10,"k":11}`,
		`{"a":["x",{"b":"y"}],"c":"z"}`,
	}
	for src in SOURCES {
		want, want_err := json.parse_string(src, .JSON)
		defer json.destroy_value(want)
		testing.expect_value(t, want_err, nil)

		for n in 0..<64 {
			f := Failing_Allocator{backing = context.allocator, left = n}
			got, err := json.parse_string(src, .JSON, false, failing_allocator(&f))
			#partial switch err {
			case nil:
				testing.expectf(t, values_equal(got, want), "%q with %d allocations: %v, want %v", src, n, got, want)
			case .Out_Of_Memory:
				testing.expectf(t, got == nil, "%q with %d allocations: %v on error", src, n, got)
			case:
				testing.expectf(t, false, "%q with %d allocations: %v", src, n, err)
			}
			json.destroy_value(got, failing_allocator(&f))
			if err == nil {
				break
			}
		}
	}
}

values_equal :: proc(a, b: json.Value) -> bool {
	switch x in a {
	case json.Null:
		_, ok := b.(json.Null)
		return ok
	case json.Integer:
		y, ok := b.(json.Integer)
		return ok && x == y
	case json.Float:
		y, ok := b.(json.Float)
		return ok && (x == y || (x != x && y != y))
	case json.Boolean:
		y, ok := b.(json.Boolean)
		return ok && x == y
	case json.String:
		y, ok := b.(json.String)
		return ok && x == y
	case json.Array:
		y, ok := b.(json.Array)
		if !ok || len(x) != len(y) {
			return false
		}
		for e, i in x {
			if !values_equal(e, y[i]) {
				return false
			}
		}
		return true
	case json.Object:
		y, ok := b.(json.Object)
		if !ok || len(x) != len(y) {
			return false
		}
		for k, e in x {
			f, found := y[k]
			if !found || !values_equal(e, f) {
				return false
			}
		}
		return true
	}
	return b == nil
}

nested :: proc(open, close: string, depth: int, inner := "1") -> string {
	b := make([dynamic]byte, 0, depth*(len(open)+len(close)) + len(inner), context.temp_allocator)
	for _ in 0..<depth {
		append(&b, open)
	}
	append(&b, inner)
	for _ in 0..<depth {
		append(&b, close)
	}
	return string(b[:])
}

Node :: struct {
	c: []Node,
}

MNode :: struct {
	m: map[string]MNode,
}

UArr :: union {
	[]UArr,
	int,
}

UMap :: union {
	map[string]UMap,
	int,
}

UStruct :: struct {
	u: UStructU,
}

UStructU :: union {
	[]UStruct,
	int,
}

Nest_Key :: enum {
	A,
}

ENode :: struct {
	e: [Nest_Key][]ENode,
}

UMapArr :: union {
	map[string]UMapArr,
	[]int,
}

typed_nesting :: proc(t: ^testing.T, $T: typeid, name, open, close, inner: string, per_level, extra: int) {
	for depth in ([]int{json.MAX_DEPTH, json.MAX_DEPTH + per_level, 100_000}) {
		levels := (depth - extra) / per_level
		src := nested(open, close, levels, inner)
		ok := levels*per_level + extra <= json.MAX_DEPTH
		for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
			x: T
			err := json.unmarshal_string(src, &x, allocator = context.temp_allocator, flags = flags)
			testing.expectf(t, (err == nil) == ok && (ok || err == json.Error.Max_Depth_Exceeded), "%s depth %d %v: %v", name, depth, flags, err)
		}

		x: T
		p := json.make_parser(src, parse_integers = true, allocator = context.temp_allocator)
		err := json.unmarshal_value(&p, x)
		testing.expectf(t, (err == nil) == ok && (ok || err == json.Error.Max_Depth_Exceeded), "%s depth %d unmarshal_value: %v", name, depth, err)
	}
}

@(test)
review_nesting_limit :: proc(t: ^testing.T) {
	Shape :: struct {
		open, close, inner: string,
		per_level:          int,
	}
	SHAPES := []Shape{
		{"[", "]", "1", 1},
		{`{"a":`, "}", "1", 1},
		{`[{"a":`, "}]", "1", 2},
	}
	for shape in SHAPES {
		for spec in ([]json.Specification{.JSON, .JSON5, .SJSON}) {
			for depth in ([]int{json.MAX_DEPTH, json.MAX_DEPTH + 1, 100_000}) {
				levels := depth / shape.per_level
				src := nested(shape.open, shape.close, levels, shape.inner)
				ok := levels*shape.per_level <= json.MAX_DEPTH

				testing.expectf(t, json.is_valid(transmute([]byte)src, spec) == ok, "%v depth %d %s: is_valid", spec, depth, shape.open)

				v, err := json.parse_string(src, spec)
				testing.expectf(t, (err == nil) == ok && (ok || err == .Max_Depth_Exceeded), "%v depth %d %s: parse %v", spec, depth, shape.open, err)
				json.destroy_value(v)

				for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
					value: json.Value
					uerr := json.unmarshal_string(src, &value, spec, flags = flags)
					testing.expectf(t, (uerr == nil) == ok && (ok || uerr == json.Error.Max_Depth_Exceeded), "%v depth %d %s %v: unmarshal %v", spec, depth, shape.open, flags, uerr)
					json.destroy_value(value)

					skipped: struct{ b: int }
					wrapped := strings.concatenate({`{"a":`, src, `,"b":2}`}, context.temp_allocator)
					serr := json.unmarshal_string(wrapped, &skipped, spec, flags = flags)
					wrapped_ok := levels*shape.per_level + 1 <= json.MAX_DEPTH
					testing.expectf(t, (serr == nil) == wrapped_ok && (wrapped_ok || serr == json.Error.Max_Depth_Exceeded), "%v depth %d %s %v: skip %v", spec, depth, shape.open, flags, serr)
				}
			}
		}
	}

	typed_nesting(t, Node,    "Node",    `{"c":[`,      "]}",  "",     2, 0)
	typed_nesting(t, MNode,   "MNode",   `{"m":{"k":`,  "}}",  "null", 2, 0)
	typed_nesting(t, UArr,    "UArr",    "[",           "]",   "1",    1, 0)
	typed_nesting(t, UMap,    "UMap",    `{"k":`,       "}",   "1",    1, 0)
	typed_nesting(t, UStruct, "UStruct", `{"u":[`,      "]}",  "",     2, 0)
	typed_nesting(t, ENode,   "ENode",   `{"e":{"A":[`, "]}}", "",     3, 0)
	typed_nesting(t, UMapArr, "UMapArr", `{"k":`,       "}",   "[]",   1, 1)

	for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		x: UArr
		p := json.make_parser(nested("[", "]", 100_000), parse_integers = true, allocator = mem.tracking_allocator(&track))
		err := json.unmarshal_value(&p, x, flags)
		testing.expectf(t, err == json.Error.Max_Depth_Exceeded && track.total_allocation_count <= 2 && len(track.allocation_map) == 0, "%v: %v after %d allocations, %d live", flags, err, track.total_allocation_count, len(track.allocation_map))
	}

	root := strings.concatenate({"a: ", nested("[", "]", json.MAX_DEPTH)}, context.temp_allocator)
	testing.expect(t, !json.is_valid(transmute([]byte)root, .SJSON))
	_, root_err := json.parse_string(root, .SJSON, allocator = context.temp_allocator)
	testing.expect_value(t, root_err, json.Error.Max_Depth_Exceeded)
}

@(test)
review_many_comments :: proc(t: ^testing.T) {
	for comment in ([]string{"/**/", "//\n", "/* a */\n"}) {
		b := make([dynamic]byte, 0, 100_000*len(comment) + 1, context.temp_allocator)
		for _ in 0..<100_000 {
			append(&b, comment)
		}
		append(&b, '1')
		for spec in ([]json.Specification{.JSON5, .SJSON}) {
			v, err := json.parse(b[:], spec)
			testing.expectf(t, err == nil && values_equal(v, json.Float(1)), "%v %q: %v, %v", spec, comment, v, err)
			testing.expectf(t, json.is_valid(b[:], spec), "%v %q: is_valid", spec, comment)
		}
	}
}

SPECS :: [3]json.Specification{.JSON, .JSON5, .SJSON}

expect_document :: proc(t: ^testing.T, src: string, spec: json.Specification, ok: bool, loc := #caller_location) {
	testing.expectf(t, json.is_valid(transmute([]byte)src, spec) == ok, "%v %q: is_valid", spec, src, loc = loc)

	v, err := json.parse_string(src, spec)
	testing.expectf(t, (err == nil) == ok && (ok || v == nil), "%v %q: parse %v, %v", spec, src, v, err, loc = loc)
	json.destroy_value(v)

	for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
		value: json.Value
		uerr := json.unmarshal_string(src, &value, spec, flags = flags)
		testing.expectf(t, (uerr == nil) == ok, "%v %q %v: unmarshal %v", spec, src, flags, uerr, loc = loc)
		json.destroy_value(value)
	}
}

@(test)
review_strict_numbers_and_strings :: proc(t: ^testing.T) {
	for src in ([]string{`[1e]`, `[01]`, `[-01]`, `[1.]`, `[1.e5]`, `[.5]`, `[1e+]`, `["\q"]`, "[\"a\x01b\"]", `["a`, `["\uZZZZ"]`, `['a']`, `[+1]`, `[-Infinity]`, `[NaN]`}) {
		expect_document(t, src, .JSON, false)
	}
	for src in ([]string{`[0e]`, `[01]`, `[-01]`, `[1e+]`, `["a`, `['a`, `["\uZZZZ"]`, `['\ug000']`}) {
		expect_document(t, src, .JSON5, false)
		expect_document(t, src, .SJSON, false)
	}
	for src in ([]string{`['a']`, `[+1]`, `[+1.5]`, `[-Infinity]`, `[-NaN]`, `[1.]`, `[1.e5]`, `[0xFF]`, `[0xab]`, `["\u00e9"]`, `['\'']`}) {
		expect_document(t, src, .JSON5, true)
		expect_document(t, src, .SJSON, true)
	}
	for src in ([]string{`[0]`, `[-0.5e-3]`, `[1E+2]`, `["\u00E9\n"]`, `{"a\u0001":1}`}) {
		for spec in SPECS {
			expect_document(t, src, spec, true)
		}
	}
	for src in ([]string{`{"\uZZZZ":1}`, `{"a":1e}`, `{"a":{"b":01}}`}) {
		for spec in SPECS {
			expect_document(t, src, spec, false)
		}
	}
	expect_document(t, `{"\q":1}`, .JSON, false)
	expect_document(t, "{\"a\x01\":1}", .JSON, false)
	expect_document(t, `{'a':1}`, .JSON, false)
	expect_document(t, `{'a':1}`, .JSON5, true)

	for spec in SPECS {
		for src in ([]string{"", "[", "[1", "[1,", "[@]", `{"a":`}) {
			v, err := json.parse_string(src, spec)
			testing.expectf(t, err == .Unexpected_Token && v == nil, "%v %q: %v, %v", spec, src, v, err)
		}
		unclosed, unclosed_err := json.parse_string(`{"a":1`, spec)
		want: json.Error = .Expected_String_For_Object_Key if spec == .SJSON else .Unexpected_Token
		testing.expectf(t, unclosed_err == want && unclosed == nil, "%v: %v, %v", spec, unclosed, unclosed_err)
		for src in ([]string{`"abc`, `["abc`}) {
			v, err := json.parse_string(src, spec)
			testing.expectf(t, err == .Invalid_String && v == nil, "%v %q: %v, %v", spec, src, v, err)
		}
	}

	testing.expect(t, !json.is_valid_string_literal(`"\uZZZZ"`, .JSON))
	testing.expect(t, !json.is_valid_string_literal(`"\ug000"`, .JSON5))
	testing.expect(t, json.is_valid_string_literal(`"\uAbCd"`, .JSON))
	testing.expect(t, !json.is_valid_number("0xZZ", .JSON5))
	testing.expect(t, !json.is_valid_number("0xfg", .JSON5))
	testing.expect(t, json.is_valid_number("0xfF", .JSON5))
	testing.expect(t, json.is_valid_number("1.e5", .JSON5))
	testing.expect(t, !json.is_valid_number("1.e5", .JSON))
	testing.expect(t, !json.is_valid_number("1.x", .JSON5))
}

@(test)
review_trailing_content :: proc(t: ^testing.T) {
	for src in ([]string{`[1] 2`, `1 2`, `[1]]`, `{} x`, `"a" "b"`, "[1]\x00garbage", "[1]\x00 ", "[1]\x00\x00]", `[1],`, `{}{}`}) {
		for spec in SPECS {
			expect_document(t, src, spec, false)
		}
	}
	for src in ([]string{"[1] \t\r\n", "1\n", "\n\t[]\r\n", "[1]\x00", "[1]\x00\x00", "[1] \n\x00", "1\x00"}) {
		for spec in SPECS {
			expect_document(t, src, spec, true)
		}
	}
	expect_document(t, `"a" `, .JSON, true)
	expect_document(t, `"a" `, .JSON5, true)
	for src in ([]string{"[1] // c\n", "[1] // c", "[1] /* c */", "[1]\n\n"}) {
		expect_document(t, src, .JSON5, true)
		expect_document(t, src, .SJSON, true)
	}
	for src in ([]string{"[1] // c", "[1] /* c */", "[/**/1]"}) {
		expect_document(t, src, .JSON, false)
	}
	for src in ([]string{"null\r\n", "[1]\n", "{a: 1}\n\n"}) {
		expect_document(t, src, .SJSON, true)
	}
	for src in ([]string{"1\n2", "[1]\n]", "[1]\n,", "a = 1\n}", "a = 1\n]"}) {
		expect_document(t, src, .SJSON, false)
	}
	for src in ([]string{"a = 1\n", "a = 1\nb = [2]\n\n", "a = 1 // c\n", "a = 1\n\x00\x00"}) {
		testing.expectf(t, json.is_valid(transmute([]byte)src, .SJSON), "%q: is_valid", src)
		v, err := json.parse_string(src, .SJSON)
		testing.expectf(t, err == nil, "%q: parse %v", src, err)
		json.destroy_value(v)
		for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
			obj: json.Object
			uerr := json.unmarshal_string(src, &obj, .SJSON, flags = flags)
			testing.expectf(t, uerr == nil && len(obj) >= 1, "%q %v: unmarshal %v, %v", src, flags, obj, uerr)
			json.destroy_value(obj)
		}
	}
}

@(test)
review_unmarshal_strict :: proc(t: ^testing.T) {
	for src in ([]string{`[1] 2`, `[1]]`, "[1]\x00x", `[1] x`}) {
		for spec in SPECS {
			x: []int
			err := json.unmarshal_string(src, &x, spec, context.temp_allocator)
			testing.expectf(t, err == json.Unmarshal_Data_Error.Invalid_Data, "%v %q: %v", spec, src, err)
			y: []int
			err = json.unmarshal_string(src, &y, spec, context.temp_allocator, {.Skip_Validation})
			testing.expectf(t, err == json.Error.Unexpected_Token, "%v %q skip: %v", spec, src, err)
		}
	}

	for src in ([]string{`[1e]`, `[01]`, `[1.]`, `[1.e5]`}) {
		x: []f64
		err := json.unmarshal_string(src, &x, .JSON, context.temp_allocator)
		testing.expectf(t, err == json.Unmarshal_Data_Error.Invalid_Data, "%q: %v", src, err)
		y: []f64
		err = json.unmarshal_string(src, &y, .JSON, context.temp_allocator, {.Skip_Validation})
		testing.expectf(t, err == json.Error.Invalid_Number, "%q skip: %v", src, err)
	}

	Known :: struct {
		b: int,
	}
	Skipped :: struct {
		src: string,
		err: json.Error,
	}
	for c in ([]Skipped{{`{"x":1e,"b":2}`, .Invalid_Number}, {`{"x":[01],"b":2}`, .Invalid_Number}, {"{\"x\":{\"a\x01\":1},\"b\":2}", .Invalid_String}, {`{"x":{"a":"\q"},"b":2}`, .Invalid_String}}) {
		k: Known
		err := json.unmarshal_string(c.src, &k, .JSON, context.temp_allocator)
		testing.expectf(t, err == json.Unmarshal_Data_Error.Invalid_Data, "%q: %v", c.src, err)
		err = json.unmarshal_string(c.src, &k, .JSON, context.temp_allocator, {.Skip_Validation})
		testing.expectf(t, err == c.err, "%q skip: %v, want %v", c.src, err, c.err)
	}

	n: int
	testing.expect(t, json.unmarshal_string(`0x10`, &n, .JSON) != nil)
	testing.expect(t, json.unmarshal_string(`"\q"`, &n, .JSON, flags = {.Skip_Validation}) == json.Error.Invalid_String)

	Lenient :: struct {
		s:   string,
		i:   int,
		f:   f64,
		inf: f64,
		h:   int,
	}
	for spec in ([]json.Specification{.JSON5, .SJSON}) {
		for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
			x: Lenient
			err := json.unmarshal_string(`{s: 'a', i: +1, f: 1.e5, inf: -Infinity, h: 0xfF}`, &x, spec, context.temp_allocator, flags)
			testing.expectf(t, err == nil && x.s == "a" && x.i == 1 && x.f == 1e5 && x.inf == 0hfff0000000000000 && x.h == 255, "%v %v: %v, %v", spec, flags, x, err)
		}
	}
}

@(test)
review_invalid_utf8 :: proc(t: ^testing.T) {
	Case :: struct {
		src, want: string,
	}
	for c in ([]Case{{"[\"a\xffb\"]", "a\uFFFDb"}, {"[\"\\n\xff\"]", "\n\uFFFD"}, {"[\"\xc0\xaf\"]", "\uFFFD\uFFFD"}, {"['\xff']", "\uFFFD"}}) {
		for spec in SPECS {
			if c.src[1] == '\'' && spec == .JSON {
				continue
			}
			testing.expectf(t, !json.is_valid(transmute([]byte)c.src, spec), "%v %q: is_valid", spec, c.src)

			v, err := json.parse_string(c.src, spec)
			arr, is_array := v.(json.Array)
			s: json.String
			if is_array && len(arr) == 1 {
				s, _ = arr[0].(json.String)
			}
			if spec == .JSON {
				testing.expectf(t, err == .Invalid_String && v == nil, "%v %q: parse %q, %v", spec, c.src, v, err)
			} else {
				testing.expectf(t, err == nil && s == c.want, "%v %q: parse %q, %v", spec, c.src, v, err)
			}
			json.destroy_value(v)

			x: []string
			uerr := json.unmarshal_string(c.src, &x, spec, context.temp_allocator)
			testing.expectf(t, uerr == json.Unmarshal_Data_Error.Invalid_Data, "%v %q: unmarshal %v", spec, c.src, uerr)
			uerr = json.unmarshal_string(c.src, &x, spec, context.temp_allocator, {.Skip_Validation})
			testing.expectf(t, uerr == json.Error.Invalid_String, "%v %q: unmarshal skip %v", spec, c.src, uerr)

			value: json.Value
			uerr = json.unmarshal_string(c.src, &value, spec, context.temp_allocator, {.Skip_Validation})
			testing.expectf(t, uerr == json.Error.Invalid_String, "%v %q: unmarshal Value skip %v", spec, c.src, uerr)
		}
	}
}

@(test)
review_unvalidated_key_with_tab :: proc(t: ^testing.T) {
	for spec in SPECS {
		m: map[string]int
		p := json.make_parser(transmute([]byte)string("{\"a\tb\":5}"), spec, true, context.temp_allocator)
		err := json.unmarshal_value(&p, m)
		if spec == .JSON {
			testing.expectf(t, err == json.Error.Invalid_String && len(m) == 0, "%v: %v, %v", spec, m, err)
		} else {
			testing.expectf(t, err == nil && len(m) == 1, "%v: %v, %v", spec, m, err)
		}
	}
}

@(test)
review_json5_comments_and_spaces :: proc(t: ^testing.T) {
	VALID := []string{
		"/***/1", "/* a **/ 1", "[1,/***/2]", "[1,/* ] **/2]",
		"// c\r1", "[1,// c\r2]", "[1,// ]\r2]", "[1,// c\u20282]", "[1,// c\u20292]", "[1,// c\r\n2]",
		"[1,\u00a02]", "[1,\u16802]", "[1,\u20002]", "[1,\u20052]", "[1,\u200a2]", "[1,\u202f2]", "[1,\u205f2]", "[1,\u30002]",
		"[1,\u20282]", "[1,\u20292]", "[1,\ufeff2]", "\u00a0[1,2]\u3000",
	}
	for src in VALID {
		expect_document(t, src, .JSON5, true)
		expect_document(t, src, .SJSON, true)
		expect_document(t, src, .JSON, false)
	}
	for src in ([]string{"/*/1", "/* */*/1", "[1,// c\n\r", "[1,\u200b2]", "[1,\u00852]", "[1,\u180e2]", "[1,\u20302]", "[1,\u20602]", "[1,\u2fff2]", "[1,\u30012]", "[1,\u00a12]"}) {
		expect_document(t, src, .JSON5, false)
	}

	for src in ([]string{"[1,/***/2]", "[1,/* ] **/2]", "[1,/*/ ] */2]", "[1,// ]\r2]", "[1,// ]\u20282]", "[1,// ]\u20292]", "[1,\u30002]"}) {
		for spec in ([]json.Specification{.JSON5, .SJSON}) {
			for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
				x: []int
				err := json.unmarshal_string(src, &x, spec, context.temp_allocator, flags)
				testing.expectf(t, err == nil && len(x) == 2 && x[0] == 1 && x[1] == 2, "%v %q %v: %v, %v", spec, src, flags, x, err)
			}
		}
	}
}

@(test)
review_json5_numbers :: proc(t: ^testing.T) {
	for src in ([]string{`[.5]`, `[-.5]`, `[+.5]`, `[.5e1]`, `[.5E-1]`, `[-.5e+1]`, `[1,.5]`, `{"a":.5}`, `[+Infinity]`, `[+NaN]`, `[0X1f]`, `[+0x10]`, `[-0X10]`, `[0x1F,2]`}) {
		expect_document(t, src, .JSON5, true)
		expect_document(t, src, .SJSON, true)
		expect_document(t, src, .JSON, false)
	}
	for src in ([]string{`[.]`, `[-.]`, `[+.]`, `[.e5]`, `[-.e5]`, `[0x]`, `[-0x]`, `[+0X]`, `[0xg]`, `[0x,1]`, `[++1]`, `[+-1]`, `[-+1]`, `[+Inf]`, `[+infinity]`}) {
		for spec in SPECS {
			expect_document(t, src, spec, false)
		}
	}

	for src in ([]string{`[.5]`, `[-.5]`, `[+.5]`}) {
		x: []f64
		err := json.unmarshal_string(src, &x, .JSON, context.temp_allocator, {.Skip_Validation})
		testing.expectf(t, err == json.Error.Unexpected_Token, "%q: %v, %v", src, x, err)
	}

	testing.expect(t, json.is_valid_number(".5", .JSON5))
	testing.expect(t, json.is_valid_number("-.5e1", .JSON5))
	testing.expect(t, !json.is_valid_number(".5", .JSON))
	testing.expect(t, !json.is_valid_number(".", .JSON5))
	testing.expect(t, !json.is_valid_number(".e1", .JSON5))
	testing.expect(t, !json.is_valid_number("-.", .JSON5))

	Hex :: struct {
		src: string,
		i:   i64,
	}
	for c in ([]Hex{{"0x1F", 31}, {"0X1f", 31}, {"0XF", 15}, {"-0x1", -1}, {"-0x10", -16}, {"+0x10", 16}, {"+0X0", 0}, {"0x7fffffffffffffff", max(i64)}, {"-0x8000000000000000", min(i64)}}) {
		for spec in ([]json.Specification{.JSON5, .SJSON}) {
			iv, ierr := json.parse_string(c.src, spec, true)
			i, is_int := iv.(json.Integer)
			testing.expectf(t, ierr == nil && is_int && i == c.i, "%v %q: %v, %v", spec, c.src, iv, ierr)
			fv, ferr := json.parse_string(c.src, spec)
			f, is_float := fv.(json.Float)
			testing.expectf(t, ferr == nil && is_float && f == f64(c.i), "%v %q: %v, %v", spec, c.src, fv, ferr)
		}
	}

	Hex_Float :: struct {
		src: string,
		f:   f64,
	}
	zeros_242 := strings.repeat("0", 242, context.temp_allocator)
	zeros_256 := strings.repeat("0", 256, context.temp_allocator)
	HEX_FLOATS := []Hex_Float{
		{"0x20000000000001", 0h4340000000000000},
		{"0x20000000000003", 0h4340000000000002},
		{"-0x20000000000003", 0hc340000000000002},
		{"0x100000000000000000000000000000000", 0h47f0000000000000},
		{"0x1" + "0000000000000" + "8" + "00000000000000000" + "0", 0h47f0000000000000},
		{"0x1" + "0000000000000" + "8" + "00000000000000000" + "1", 0h47f0000000000001},
		{"0x1" + "0000000000000" + "8" + "00000000000000000" + "0" + "0000000001", 0h4a70000000000001},
		{strings.concatenate({"0xFFFFFFFFFFFFF8", zeros_242}, context.temp_allocator), 0h7fefffffffffffff},
		{strings.concatenate({"0x1", zeros_256}, context.temp_allocator), 0h7ff0000000000000},
		{strings.concatenate({"-0x1", zeros_256}, context.temp_allocator), 0hfff0000000000000},
	}
	for c in HEX_FLOATS {
		for spec in ([]json.Specification{.JSON5, .SJSON}) {
			v, err := json.parse_string(c.src, spec)
			f, is_float := v.(json.Float)
			testing.expectf(t, err == nil && is_float && transmute(u64)f == transmute(u64)c.f, "%v %q: %v, %v", spec, c.src, v, err)
		}
	}

	for spec in ([]json.Specification{.JSON5, .SJSON}) {
		for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
			fs: []f64
			err := json.unmarshal_string(`[-0x10, 0x1F, .5, +Infinity, +.5e1, 0X0, 0xe, 0xE1, -.5E-1, 1e+2]`, &fs, spec, context.temp_allocator, flags)
			testing.expectf(t, err == nil && len(fs) == 10 && fs[0] == -16 && fs[1] == 31 && fs[2] == 0.5 && fs[3] == 0h7ff0000000000000 && fs[4] == 5 && fs[5] == 0 && fs[6] == 14 && fs[7] == 225 && fs[8] == -0.05 && fs[9] == 100, "%v %v: %v, %v", spec, flags, fs, err)

			is: []i64
			err = json.unmarshal_string(`[-0x10, 0x1F, +0x7fffffffffffffff, 0X0, +1, 0xabc, 0xe]`, &is, spec, context.temp_allocator, flags)
			testing.expectf(t, err == nil && len(is) == 7 && is[0] == -16 && is[1] == 31 && is[2] == max(i64) && is[3] == 0 && is[4] == 1 && is[5] == 2748 && is[6] == 14, "%v %v: %v, %v", spec, flags, is, err)

			wide: []i128
			err = json.unmarshal_string(`[0x7fffffffffffffffffffffffffffffff, -0x80000000000000000000000000000000]`, &wide, spec, context.temp_allocator, flags)
			testing.expectf(t, err == nil && len(wide) == 2 && wide[0] == max(i128) && wide[1] == min(i128), "%v %v: %v, %v", spec, flags, wide, err)
		}

		m: map[i128]int
		err := json.unmarshal_string(`{"0x7fffffffffffffffffffffffffffffff": 1, "-0x80000000000000000000000000000000": 2, "0X1f": 3}`, &m, spec, context.temp_allocator)
		testing.expectf(t, err == nil && len(m) == 3 && m[max(i128)] == 1 && m[min(i128)] == 2 && m[31] == 3, "%v: %v, %v", spec, m, err)
		for src in ([]string{`{"0x80000000000000000000000000000000": 1}`, `{"-0x80000000000000000000000000000001": 1}`, `{"0x100000000000000000000000000000000": 1}`}) {
			o: map[i128]int
			err = json.unmarshal_string(src, &o, spec, context.temp_allocator)
			testing.expectf(t, err != nil, "%v %q: %v, %v", spec, src, o, err)
		}

		floats: []f64
		p := json.make_parser(`[0x1F, -0x10, 0x20000000000003]`, spec, false, context.temp_allocator)
		err = json.unmarshal_value(&p, floats)
		testing.expectf(t, err == nil && len(floats) == 3 && floats[0] == 31 && floats[1] == -16 && floats[2] == 0h4340000000000002, "%v: %v, %v", spec, floats, err)
	}
}

@(test)
review_json5_strings :: proc(t: ^testing.T) {
	Case :: struct {
		src, want: string,
	}
	CASES := []Case{
		{"[\"a\\\nb\"]", "ab"},
		{"[\"a\\\rb\"]", "ab"},
		{"[\"a\\\r\nb\"]", "ab"},
		{"[\"a\\\xe2\x80\xa8b\"]", "ab"},
		{"[\"a\\\xe2\x80\xa9b\"]", "ab"},
		{"[\"\\\n\"]", ""},
		{"['a\\\r\nb']", "ab"},
		{"[\"\\x41\"]", "A"},
		{"[\"\\xe9\\xFF\"]", "\xc3\xa9\xc3\xbf"},
		{"[\"a\\0b\"]", "a\x00b"},
		{"[\"\\0\"]", "\x00"},
		{"[\"\\v\"]", "\v"},
		{"[\"\\q\"]", "q"},
		{"[\"\\\xc3\xa9\"]", "\xc3\xa9"},
		{"[\"\\\xe2\x80\xaf\"]", "\xe2\x80\xaf"},
		{"[\"\\\t\"]", "\t"},
		{"[\"a\tb\"]", "a\tb"},
		{"[\"a\x01\x1fb\"]", "a\x01\x1fb"},
		{"[\"\\x41\\\n\\q\t\"]", "Aq\t"},
		{"['\\q\t\\'']", "q\t'"},
	}
	for c in CASES {
		for spec in ([]json.Specification{.JSON5, .SJSON}) {
			expect_document(t, c.src, spec, true)

			v, err := json.parse_string(c.src, spec)
			arr, _ := v.(json.Array)
			s: json.String
			if len(arr) == 1 {
				s, _ = arr[0].(json.String)
			}
			testing.expectf(t, err == nil && s == c.want, "%v %q: parse %q, %v", spec, c.src, v, err)
			json.destroy_value(v)

			for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
				x: []string
				uerr := json.unmarshal_string(c.src, &x, spec, context.temp_allocator, flags)
				testing.expectf(t, uerr == nil && len(x) == 1 && x[0] == c.want, "%v %q %v: unmarshal %q, %v", spec, c.src, flags, x, uerr)
			}
		}
		expect_document(t, c.src, .JSON, false)
	}

	for src in ([]string{"[\"\\1\"]", "[\"\\9\"]", "[\"\\01\"]", "[\"\\08\"]", "[\"\\x4\"]", "[\"\\x\"]", "[\"\\xg1\"]", "[\"\\x4g\"]", "[\"a\rb\"]", "[\"a\nb\"]", "[\"\\q\r\"]", "[\"\\", "['\\x4']", "{\"\\1\":1}"}) {
		for spec in SPECS {
			expect_document(t, src, spec, false)
		}
	}

	for lit in ([]string{"\"a\nb\"", "\"a\rb\"", "\"\\qa\nb\"", "\"\\qa\rb\"", "\"\x01\\1\""}) {
		testing.expectf(t, !json.is_valid_string_literal(lit, .JSON5), "%q", lit)
	}
	for lit in ([]string{"\"a\tb\"", "\"\\qa\tb\"", "\"\\qa\x01b\""}) {
		testing.expectf(t, json.is_valid_string_literal(lit, .JSON5), "%q", lit)
		testing.expectf(t, !json.is_valid_string_literal(lit, .JSON), "%q", lit)
	}

	for spec in ([]json.Specification{.JSON5, .SJSON}) {
		for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
			x: []string
			err := json.unmarshal_string("[\"a\\\r\nb\", \"c\", 'd\\\re', \"\\\r\n\"]", &x, spec, context.temp_allocator, flags)
			testing.expectf(t, err == nil && len(x) == 4 && x[0] == "ab" && x[1] == "c" && x[2] == "de" && x[3] == "", "%v %v: %q, %v", spec, flags, x, err)

			m: map[string]int
			err = json.unmarshal_string("{\"a\\qb\": 1, \"c\\\r\nd\": 2, \"\\x41\": 3}", &m, spec, context.temp_allocator, flags)
			testing.expectf(t, err == nil && len(m) == 3 && m["aqb"] == 1 && m["cd"] == 2 && m["A"] == 3, "%v %v: %v, %v", spec, flags, m, err)

			Fields :: struct {
				aqb, cd: int,
			}
			f: Fields
			err = json.unmarshal_string("{\"a\\qb\": 1, \"c\\\nd\": 2}", &f, spec, context.temp_allocator, flags)
			testing.expectf(t, err == nil && f.aqb == 1 && f.cd == 2, "%v %v: %v, %v", spec, flags, f, err)
		}
	}
}

@(test)
review_json5_keys_and_commas :: proc(t: ^testing.T) {
	for src in ([]string{`{$a:1}`, `{a$:1}`, `{$:1}`, `{_$1:1}`, `{null:1}`, `{true:1}`, `{false:1}`, `{Infinity:1}`, `{NaN:1}`, `{if:1}`, `{a:1,null:2}`, `{a:{$b:[1,2,]},}`, "{\xc2\xa0$a:1}"}) {
		expect_document(t, src, .JSON5, true)
		expect_document(t, src, .SJSON, true)
		expect_document(t, src, .JSON, false)
	}
	for src in ([]string{`{-Infinity:1}`, `{+NaN:1}`, `{-NaN:1}`, `{1:1}`, `{a b:1}`, `[1,,2]`, `[,1]`, `{,}`, `[$]`}) {
		expect_document(t, src, .JSON, false)
		expect_document(t, src, .JSON5, false)
	}
	for src in ([]string{`[1 2]`, `{a:1 b:2}`, `[[] []]`, `{"a":1 "b":2}`, `[1 /**/ 2]`}) {
		expect_document(t, src, .JSON5, false)
		expect_document(t, src, .SJSON, true)
	}
	expect_document(t, "[1\n2]", .JSON5, false)
	expect_document(t, "[1\n2]", .SJSON, true)
	expect_document(t, `["$"]`, .JSON, true)
	expect_document(t, `{"a":1}`, .JSON, true)

	for spec in ([]json.Specification{.JSON5, .SJSON}) {
		v, err := json.parse_string(`{null: 1, $a: 2, true: 3, NaN: 4}`, spec)
		obj, _ := v.(json.Object)
		null_value, _ := obj["null"].(json.Float)
		testing.expectf(t, err == nil && len(obj) == 4 && null_value == 1 && "$a" in obj && "true" in obj && "NaN" in obj, "%v: %v, %v", spec, v, err)
		json.destroy_value(v)

		for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
			m: map[string]int
			uerr := json.unmarshal_string(`{null: 1, $a: 2, true: 3, a$b: 4}`, &m, spec, context.temp_allocator, flags)
			testing.expectf(t, uerr == nil && len(m) == 4 && m["null"] == 1 && m["$a"] == 2 && m["true"] == 3 && m["a$b"] == 4, "%v %v: %v, %v", spec, flags, m, uerr)

			Tagged :: struct {
				t: int `json:"true"`,
				d: int `json:"$d"`,
			}
			x: Tagged
			uerr = json.unmarshal_string(`{true: 1, $d: 2}`, &x, spec, context.temp_allocator, flags)
			testing.expectf(t, uerr == nil && x.t == 1 && x.d == 2, "%v %v: %v, %v", spec, flags, x, uerr)

			y: Tagged
			uerr = json.unmarshal_string(`{other: {null: 1, $q: [1, 2]}, true: 5}`, &y, spec, context.temp_allocator, flags)
			testing.expectf(t, uerr == nil && y.t == 5, "%v %v: %v, %v", spec, flags, y, uerr)
		}
	}

	for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
		words: []string
		err := json.unmarshal_string(`[$a, b$c, $]`, &words, .SJSON, context.temp_allocator, flags)
		testing.expectf(t, err == nil && len(words) == 3 && words[0] == "$a" && words[1] == "b$c" && words[2] == "$", "%v: %v, %v", flags, words, err)

		x: []int
		err = json.unmarshal_string(`[1 2]`, &x, .JSON5, context.temp_allocator, flags)
		testing.expectf(t, err != nil, "%v: %v, %v", flags, x, err)
		y: []int
		err = json.unmarshal_string(`[1 2]`, &y, .SJSON, context.temp_allocator, flags)
		testing.expectf(t, err == nil && len(y) == 2 && y[0] == 1 && y[1] == 2, "%v: %v, %v", flags, y, err)
	}

	Tok :: struct {
		src:  string,
		spec: json.Specification,
		kind: json.Token_Kind,
		text: string,
		err:  json.Error,
	}
	for c in ([]Tok{{"$a", .JSON5, .Ident, "$a", nil}, {"a$b", .SJSON, .Ident, "a$b", nil}, {"$", .JSON, .Invalid, "$", .Illegal_Character}, {"true$", .JSON, .True, "true", nil}, {"a$", .JSON, .Ident, "a", nil}}) {
		tz := json.make_tokenizer(c.src, c.spec)
		tok, err := json.get_token(&tz)
		testing.expectf(t, tok.kind == c.kind && tok.text == c.text && err == c.err, "%v %q: %v %q %v", c.spec, c.src, tok.kind, tok.text, err)
	}

	Named :: struct {
		x: int,
	}
	for spec in SPECS {
		n: Named
		err := json.unmarshal_string(`{"x": [1, 2`, &n, spec, flags = {.Skip_Validation})
		testing.expectf(t, err == json.Error.EOF, "%v: %v", spec, err)
		err = json.unmarshal_string(`{"x": [1, 2}`, &n, spec, flags = {.Skip_Validation})
		testing.expectf(t, err == json.Error.Unexpected_Token, "%v: %v", spec, err)
	}
}

@(private="file")
pos_at :: proc(src: string, offset: int) -> json.Pos {
	pos := json.Pos{offset = offset, line = 1, column = offset + 1}
	for i in 0..<offset {
		if src[i] == '\n' {
			pos.line += 1
			pos.column = offset - i
		}
	}
	return pos
}

@(test)
review_positions :: proc(t: ^testing.T) {
	SOURCES :: [?]string{
		"/* x\n y */ 1\n2",
		"[1,\r\n 2]",
		"[\"a\\\nb\", 1]",
		"[\"a\\\r\nb\", 1]",
		"['a\\\nb', 'c\\\n\\\nd', 1]",
		"\xc2\xa0\"a\\\nb\" 1",
		"\xc2\xa0'a\\\r\nb' 1",
		"a = 1\nb = 2\n\nc = [\n3\n]",
		"// c\n1",
		"/*\r\n\r\n*/2",
		"[1, /* x\n y",
		"{\n  \"k\": [\n    1,\n    2.5e3\n  ],\n  \"s\": \"x\\ny\"\n}",
		"\xef\xbb\xbf[1,\n2]",
		"[1,\n @]",
		"[\"a\\\nb",
		"\"a\nb\" 1",
		"[\n\"\x5cu0041\", \"\\x41\\\n\", 3]",
		"[0x1f,\n.5, +Infinity,\n-NaN]",
		"[1,\xc2\xa0\n 2,\xe2\x80\xa8\n\n3]",
		"",
	}
	for src in SOURCES {
		for spec in SPECS {
			for validated in ([]bool{false, true}) {
				if validated && !json.is_valid(transmute([]byte)src, spec) {
					continue
				}
				tz := json.make_tokenizer(src, spec)
				tz.validated = validated
				for _ in 0..<64 {
					tok, err := json.get_token(&tz)
					testing.expectf(t, tok.pos == pos_at(src, tok.pos.offset), "%v %v %q: %q at %v", spec, validated, src, tok.text, tok.pos)
					testing.expectf(t, tz.pos == pos_at(src, tz.pos.offset), "%v %v %q: after %q at %v", spec, validated, src, tok.text, tz.pos)
					inserted := tok.kind == .Comma && tok.pos.offset < len(src) && src[tok.pos.offset] == '\n'
					if !inserted {
						testing.expectf(t, json.token_end_pos(tok) == tz.pos, "%v %v %q: %q ends at %v, tokenizer at %v", spec, validated, src, tok.text, json.token_end_pos(tok), tz.pos)
					}
					if err != nil || tok.kind == .EOF {
						break
					}
				}
			}
		}
	}

	Pin :: struct {
		src:  string,
		spec: json.Specification,
		text: string,
		pos:  json.Pos,
	}
	for c in ([]Pin{
		{"/* x\n y */ 1\n2", .JSON5, "1", {11, 2, 7}},
		{"/* x\n y */ 1\n2", .JSON5, "2", {13, 3, 1}},
		{"[1]", .JSON, "]", {2, 1, 3}},
		{"a = 1\nb = 2", .SJSON, "b", {6, 2, 1}},
		{"[\"a\\\nb\", 1]", .JSON5, "1", {9, 2, 5}},
	}) {
		tz := json.make_tokenizer(c.src, c.spec)
		found := false
		for _ in 0..<16 {
			tok, err := json.get_token(&tz)
			if tok.text == c.text {
				found = true
				testing.expectf(t, tok.pos == c.pos, "%v %q: %q at %v", c.spec, c.src, c.text, tok.pos)
				break
			}
			if err != nil {
				break
			}
		}
		testing.expectf(t, found, "%v %q: no %q", c.spec, c.src, c.text)
	}

	tz := json.make_tokenizer("\"a\\\nbc\"", .JSON5)
	tok, _ := json.get_token(&tz)
	testing.expectf(t, json.token_end_pos(tok) == json.Pos{7, 2, 4}, "%v", json.token_end_pos(tok))
	tz = json.make_tokenizer("true", .JSON)
	tok, _ = json.get_token(&tz)
	testing.expectf(t, json.token_end_pos(tok) == json.Pos{4, 1, 5}, "%v", json.token_end_pos(tok))
}

@(test)
review_quiet_nan :: proc(t: ^testing.T) {
	qnan := transmute(u64)math.nan_f64()
	for spec in ([]json.Specification{.JSON5, .SJSON}) {
		v, err := json.parse_string("[NaN, -NaN]", spec)
		defer json.destroy_value(v)
		a, ok := v.(json.Array)
		testing.expectf(t, err == nil && ok && len(a) == 2, "%v: %v %v", spec, v, err)
		if ok && len(a) == 2 {
			x, _ := a[0].(json.Float)
			y, _ := a[1].(json.Float)
			testing.expectf(t, transmute(u64)x == qnan && transmute(u64)y == qnan | 1 << 63, "%v: %x %x", spec, transmute(u64)x, transmute(u64)y)
		}

		fs: [2]f64
		uerr := json.unmarshal_string("[NaN, -NaN]", &fs, spec)
		testing.expectf(t, uerr == nil && transmute(u64)fs[0] == qnan && transmute(u64)fs[1] == qnan | 1 << 63, "%v: %x %v", spec, transmute([2]u64)fs, uerr)
	}
}

@(test)
review_marshal_non_finite_round_trip :: proc(t: ^testing.T) {
	Floats :: struct {
		nan:     f64,
		neg_nan: f64,
		inf:     f64,
		neg_inf: f64,
		nan32:   f32,
		inf16:   f16,
		arr:     [2]f64,
		m:       map[string]f64,
	}
	src := Floats{
		nan     = math.nan_f64(),
		neg_nan = -math.nan_f64(),
		inf     = math.inf_f64(1),
		neg_inf = math.inf_f64(-1),
		nan32   = math.nan_f32(),
		inf16   = math.inf_f16(-1),
		arr     = {math.inf_f64(1), math.nan_f64()},
	}
	src.m = make(map[string]f64, context.temp_allocator)
	src.m["x"] = math.inf_f64(-1)

	_, json_err := json.marshal(src, {spec = .JSON}, context.temp_allocator)
	testing.expectf(t, json_err == json.Marshal_Data_Error.Non_Finite_Float, "JSON: %v", json_err)

	qnan := transmute(u64)math.nan_f64()
	for spec in ([]json.Specification{.JSON5, .SJSON}) {
		data, err := json.marshal(src, {spec = spec}, context.temp_allocator)
		testing.expectf(t, err == nil, "%v: marshal %v", spec, err)
		for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
			dst: Floats
			uerr := json.unmarshal(data, &dst, spec, context.temp_allocator, flags)
			testing.expectf(t, uerr == nil, "%v %v %s: %v", spec, flags, data, uerr)
			testing.expectf(t, transmute(u64)dst.nan == qnan && math.is_nan(dst.neg_nan), "%v %v: %v", spec, flags, dst)
			testing.expectf(t, dst.inf == math.inf_f64(1) && dst.neg_inf == math.inf_f64(-1), "%v %v: %v", spec, flags, dst)
			testing.expectf(t, math.is_nan(dst.nan32) && dst.inf16 == math.inf_f16(-1), "%v %v: %v", spec, flags, dst)
			testing.expectf(t, dst.arr[0] == math.inf_f64(1) && transmute(u64)dst.arr[1] == qnan && dst.m["x"] == math.inf_f64(-1), "%v %v: %v", spec, flags, dst)
		}
	}
}

@(test)
review_match_ignore_key_not_found :: proc(t: ^testing.T) {
	v, err := json.parse_string(`{"a": {"b": 1}, "c": [2]}`)
	defer json.destroy_value(v)
	testing.expect_value(t, err, nil)

	found, merr := json.match(v, "missing", "x", flags = {.Ignore_Key_Not_Found})
	testing.expectf(t, found == nil && merr == .None, "%v %v", found, merr)
	found, merr = json.match(v, "a", "missing", 0, flags = {.Ignore_Key_Not_Found})
	testing.expectf(t, found == nil && merr == .None, "%v %v", found, merr)
	found, merr = json.match(v, "missing", "x")
	testing.expectf(t, merr == .Key_Not_Found, "%v %v", found, merr)
	found, merr = json.match(v, "a", "b", flags = {.Ignore_Key_Not_Found})
	b, _ := found.(json.Float)
	testing.expectf(t, merr == .None && b == 1, "%v %v", found, merr)
	found, merr = json.match(v, "c", "x", flags = {.Ignore_Key_Not_Found})
	testing.expectf(t, merr == .Invalid_Type_For_Key, "%v %v", found, merr)
	found, merr = json.match(v, "c", 0, flags = {.Ignore_Key_Not_Found})
	c, _ := found.(json.Float)
	testing.expectf(t, merr == .None && c == 2, "%v %v", found, merr)
}

@(test)
review_unmarshal_value_unvalidated :: proc(t: ^testing.T) {
	S :: struct {
		a: int,
		b: []int,
	}
	SOURCES :: [?]string{
		`{"a" 1}`,
		`{"a": 1`,
		`{"a": 1 "b": [2]}`,
		`{"b": [1, 2`,
		`{"b": [1 2]}`,
		`{"b": [1, 2}`,
		`{"b": [1,, 2]}`,
		`{"a": 1e}`,
		`{"a": 01}`,
		`{"a":}`,
		`{"a": 1,`,
		`{,}`,
		`{"c": {"d" 1}}`,
		`{"c": [1e]}`,
		`{"c": "x\q"}`,
		`{"a": 1, "b": [2, 3]}`,
	}
	for src in SOURCES {
		for spec in SPECS {
			s, s_skip: S
			p := json.make_parser(transmute([]byte)src, spec, true, context.temp_allocator)
			err := json.unmarshal_value(&p, s)
			err_skip := json.unmarshal_string(src, &s_skip, spec, context.temp_allocator, {.Skip_Validation})
			e, _ := err.(json.Error)
			e_skip, _ := err_skip.(json.Error)
			testing.expectf(t, (err == nil) == (err_skip == nil) && e == e_skip, "%v %q: %v, skip validation %v", spec, src, err, err_skip)

			m: map[string]int
			p = json.make_parser(transmute([]byte)src, spec, true, context.temp_allocator)
			err = json.unmarshal_value(&p, m)
			testing.expectf(t, err != nil || src == `{"a": 1, "b": [2, 3]}`, "%v %q: %v", spec, src, err)
		}
	}

	for spec in SPECS {
		m: map[string]int
		p := json.make_parser(transmute([]byte)string(`{"a" 1}`), spec, true, context.temp_allocator)
		err := json.unmarshal_value(&p, m)
		testing.expectf(t, err == json.Error.Expected_Colon_After_Key, "%v: %v", spec, err)

		a: [dynamic]int
		p = json.make_parser(transmute([]byte)string(`[1, 2`), spec, true, context.temp_allocator)
		err = json.unmarshal_value(&p, a)
		testing.expectf(t, err == json.Error.EOF, "%v: %v", spec, err)
	}
}

@(test)
review_unmarshal_nil_pointer :: proc(t: ^testing.T) {
	p: ^int
	err := json.unmarshal_string("1", p)
	testing.expectf(t, err == json.Unmarshal_Data_Error.Invalid_Parameter, "%v", err)
	err = json.unmarshal_string("[", p)
	testing.expectf(t, err == json.Unmarshal_Data_Error.Invalid_Parameter, "%v", err)
}

@(test)
review_unmarshal_bit_set_128 :: proc(t: ^testing.T) {
	S :: struct {
		flags:    bit_set[0..<128],
		flags_be: bit_set[0..<128; u128be],
		flags_le: bit_set[0..<128; u128le],
	}
	s: S
	err := json.unmarshal_string(`{"flags": 5, "flags_be": 5, "flags_le": 5}`, &s)
	testing.expectf(t, err == nil && s.flags == {0, 2} && s.flags_be == {0, 2} && s.flags_le == {0, 2}, "%v %v", s, err)
	err = json.unmarshal_string(`{"flags": -170141183460469231731687303715884105728}`, &s)
	testing.expectf(t, err == nil && s.flags == {127}, "%v %v", s, err)
}

@(test)
review_unmarshal_string16_map_keys :: proc(t: ^testing.T) {
	m16: map[string16]int
	err := json.unmarshal_string(`{"a": 1}`, &m16)
	_, unsupported := err.(json.Unsupported_Type_Error)
	testing.expectf(t, unsupported && len(m16) == 0, "%v %v", m16, err)

	mc16: map[cstring16]int
	err = json.unmarshal_string(`{"a": 1}`, &mc16)
	_, unsupported = err.(json.Unsupported_Type_Error)
	testing.expectf(t, unsupported && len(mc16) == 0, "%v %v", mc16, err)
}

@(test)
review_unmarshal_array_size_overflow :: proc(t: ^testing.T) {
	N :: 1 << 20 when size_of(int) == 8 else 1 << 10
	Big :: [N][N][N]u8
	SRC :: `[[[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]], [[[1]]]]`
	for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
		s: []Big
		err := json.unmarshal_string(SRC, &s, flags = flags)
		testing.expectf(t, err == json.Error.Out_Of_Memory && s == nil, "%v: %v", flags, err)

		d: [dynamic]Big
		err = json.unmarshal_string(SRC, &d, flags = flags)
		testing.expectf(t, err == json.Error.Out_Of_Memory && d == nil, "%v: %v", flags, err)
	}
}

@(test)
review_unmarshal_field_error_empty_key :: proc(t: ^testing.T) {
	Inner :: struct {
		a: int `json:""`,
	}
	Outer :: struct {
		i: Inner `json:""`,
	}
	for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
		o: Outer
		err := json.unmarshal_string(`{"": {"": "x"}}`, &o, flags = flags)
		e, is_type := err.(json.Unsupported_Type_Error)
		testing.expectf(t, is_type && e.field == "" && e.id == typeid_of(int), "%v: %v", flags, err)
		delete(e.field)

		ok: Outer
		err = json.unmarshal_string(`{"": {"": 5}}`, &ok, flags = flags)
		testing.expectf(t, err == nil && ok.i.a == 5, "%v: %v %v", flags, ok, err)
	}
}

@(test)
review_unmarshal_unvalidated_errors :: proc(t: ^testing.T) {
	S :: struct {
		a: int,
	}
	Case :: struct {
		src:  string,
		want: json.Error,
	}
	SCALAR_CASES :: [?]Case{
		{`{"a": }`,   .Unexpected_Token},
		{`{"a": ]}`,  .Unexpected_Token},
		{`{"a": :}`,  .Unexpected_Token},
		{`{"a": ,}`,  .Unexpected_Token},
	}
	for c in SCALAR_CASES {
		for spec in SPECS {
			s, s_skip: S
			p := json.make_parser(transmute([]byte)c.src, spec, true, context.temp_allocator)
			err := json.unmarshal_value(&p, s)
			testing.expectf(t, err == c.want, "%v %q: %v", spec, c.src, err)
			err = json.unmarshal_string(c.src, &s_skip, spec, context.temp_allocator, {.Skip_Validation})
			testing.expectf(t, err == c.want, "%v %q: skip validation %v", spec, c.src, err)
		}
	}

	m: map[string]int
	err := json.unmarshal_string(`{1: 2}`, &m, .JSON, context.temp_allocator, {.Skip_Validation})
	testing.expectf(t, err == json.Error.Expected_String_For_Object_Key && len(m) == 0, "%v %v", m, err)

	e: [enum{A, B}]int
	err = json.unmarshal_string(`{1: 2}`, &e, .JSON, context.temp_allocator, {.Skip_Validation})
	testing.expectf(t, err == json.Error.Expected_String_For_Object_Key, "%v %v", e, err)

	for flags in ([]json.Unmarshal_Flags{{}, {.Skip_Validation}}) {
		for n in 0..<32 {
			f := Failing_Allocator{backing = context.temp_allocator, left = n}
			ab: map[string]int
			ab_err := json.unmarshal_string(`{"a": 1, "b": 2}`, &ab, .JSON, failing_allocator(&f), flags)
			if ab_err == nil {
				testing.expectf(t, len(ab) == 2 && ab["a"] == 1 && ab["b"] == 2, "%v with %d allocations: %v", flags, n, ab)
				break
			}
			testing.expectf(t, ab_err == json.Error.Out_Of_Memory, "%v with %d allocations: %v", flags, n, ab_err)
		}
	}
}

@(test)
review_unmarshal_number_text_grammar :: proc(t: ^testing.T) {
	Int_Case :: struct {
		text:  string,
		value: i32,
		json:  bool,
		json5: bool,
	}
	INT_CASES :: []Int_Case{
		{`"10"`,    10,  true,  true},
		{`"-0"`,    0,   true,  true},
		{`"-5"`,    -5,  true,  true},
		{`"0x10"`,  16,  false, true},
		{`"0X10"`,  16,  false, true},
		{`"-0x10"`, -16, false, true},
		{`"+5"`,    5,   false, true},
		{`"1_000"`, 0,   false, false},
		{`"0b101"`, 0,   false, false},
		{`"0o17"`,  0,   false, false},
		{`"0z10"`,  0,   false, false},
		{`"0h10"`,  0,   false, false},
		{`"01"`,    0,   false, false},
		{`" 1"`,    0,   false, false},
		{`"1 "`,    0,   false, false},
		{`""`,      0,   false, false},
		{`"-"`,     0,   false, false},
		{`"1.0"`,   0,   false, false},
		{`"1e3"`,   0,   false, false},
		{`"NaN"`,   0,   false, false},
	}
	for spec in SPECS {
		for c in INT_CASES {
			want := c.json if spec == .JSON else c.json5
			src := fmt.tprintf("[%s]", c.text)
			v: [1]i32
			err := json.unmarshal_string(src, &v, spec, context.temp_allocator)
			if want {
				testing.expectf(t, err == nil && v[0] == c.value, "%v %s: %v %v", spec, c.text, v[0], err)
			} else {
				_, is_type := err.(json.Unsupported_Type_Error)
				testing.expectf(t, is_type, "%v %s: %v %v", spec, c.text, v[0], err)
			}

			key_src := fmt.tprintf("{{%s: 1}}", c.text)
			m: map[i32]int
			err = json.unmarshal_string(key_src, &m, spec, context.temp_allocator)
			if want {
				testing.expectf(t, err == nil && len(m) == 1 && m[c.value] == 1, "%v %s: %v %v", spec, key_src, m, err)
			} else {
				testing.expectf(t, err != nil, "%v %s: %v %v", spec, key_src, m, err)
			}
		}
	}

	Float_Case :: struct {
		text:  string,
		value: f64,
		json:  bool,
		json5: bool,
	}
	FLOAT_CASES :: []Float_Case{
		{`"1.5"`,                0h3ff8000000000000, true,  true},
		{`"-0"`,                 0h8000000000000000, true,  true},
		{`"1e3"`,                0h408f400000000000, true,  true},
		{`"7"`,                  0h401c000000000000, true,  true},
		{`"Infinity"`,           0h7ff0000000000000, false, true},
		{`"+Infinity"`,          0h7ff0000000000000, false, true},
		{`"-Infinity"`,          0hfff0000000000000, false, true},
		{`".5"`,                 0h3fe0000000000000, false, true},
		{`"+1.5"`,               0h3ff8000000000000, false, true},
		{`"5."`,                 0h4014000000000000, false, true},
		{`"+.5"`,                0h3fe0000000000000, false, true},
		{`"-5.e1"`,              0hc049000000000000, false, true},
		{`"0x10"`,               0h4030000000000000, false, true},
		{`"nan"`,                0, false, false},
		{`"-nan"`,               0, false, false},
		{`"NAN"`,                0, false, false},
		{`"inf"`,                0, false, false},
		{`"-inf"`,               0, false, false},
		{`"infinity"`,           0, false, false},
		{`"0h3ff0000000000000"`, 0, false, false},
		{`"1_0.5"`,              0, false, false},
		{`"0x1p4"`,              0, false, false},
		{`"1.5 "`,               0, false, false},
	}
	for spec in SPECS {
		for c in FLOAT_CASES {
			want := c.json if spec == .JSON else c.json5
			src := fmt.tprintf("[%s]", c.text)
			v: [1]f64
			err := json.unmarshal_string(src, &v, spec, context.temp_allocator)
			if want {
				testing.expectf(t, err == nil && transmute(u64)v[0] == transmute(u64)c.value, "%v %s: %v %v", spec, c.text, v[0], err)
			} else {
				_, is_type := err.(json.Unsupported_Type_Error)
				testing.expectf(t, is_type, "%v %s: %v %v", spec, c.text, v[0], err)
			}
		}
		for text in ([]string{`["NaN"]`, `["+NaN"]`, `["-NaN"]`}) {
			v: [1]f64
			err := json.unmarshal_string(text, &v, spec, context.temp_allocator)
			if spec == .JSON {
				_, is_type := err.(json.Unsupported_Type_Error)
				testing.expectf(t, is_type, "%v %s: %v %v", spec, text, v[0], err)
				continue
			}
			want: f64 = 0hfff8000000000001 if text[2] == '-' else 0h7ff8000000000001
			testing.expectf(t, err == nil && transmute(u64)v[0] == transmute(u64)want, "%v %s: %v %v", spec, text, v[0], err)
		}
	}

	S :: struct {
		f: f64,
		i: int,
	}
	for text in ([]string{"f = nan", "f = NAN", "f = inf", "f = Inf", "f = infinity", "f = -nan", "f = -inf", "i = abc"}) {
		s: S
		err := json.unmarshal_string(text, &s, .SJSON, context.temp_allocator)
		testing.expectf(t, err != nil && s == {}, "%s: %v %v", text, s, err)
	}
	s: S
	err := json.unmarshal_string("f = -Infinity, i = 0x10", &s, .SJSON, context.temp_allocator)
	testing.expectf(t, err == nil && s.f == math.inf_f64(-1) && s.i == 16, "%v %v", s, err)
}


@(test)
review_unmarshal_union_best_fit :: proc(t: ^testing.T) {
	A :: struct {
		a: int,
	}
	B :: struct {
		b: string,
	}
	AB :: union {
		A,
		B,
	}
	for spec in SPECS {
		ab: AB
		err := json.unmarshal_string(`{"b": "Hellope"}`, &ab, spec)
		b, is_b := ab.(B)
		testing.expectf(t, err == nil && is_b && b.b == "Hellope", "%v: %v %v", spec, ab, err)
		delete(b.b)

		for src in ([]string{`{"a": 1}`, `{"a": 1, "c": 2}`, `{"c": 2}`, `{}`}) {
			ab = nil
			err = json.unmarshal_string(src, &ab, spec)
			a, is_a := ab.(A)
			testing.expectf(t, err == nil && is_a && a.a == (0 if src == `{"c": 2}` || src == `{}` else 1), "%v %s: %v %v", spec, src, ab, err)
		}
	}

	written, merr := json.marshal(AB(B{b = "x"}), allocator = context.temp_allocator)
	back: AB
	err := json.unmarshal(written, &back, allocator = context.temp_allocator)
	back_b, back_is_b := back.(B)
	testing.expectf(t, merr == nil && err == nil && back_is_b && back_b.b == "x", "%s: %v %v %v", written, back, merr, err)

	A2 :: struct {
		a, bad: int,
	}
	B2 :: struct {
		b, c: int,
	}
	stale: union{A2, B2}
	err = json.unmarshal_string(`{"a": 5, "bad": "zz"}`, &stale)
	b2, is_b2 := stale.(B2)
	testing.expectf(t, err == nil && is_b2 && b2 == {}, "%v %v", stale, err)

	A3 :: struct {
		name: string,
		n:    int,
	}
	B3 :: struct {
		name, n: string,
	}
	AB3 :: union {
		A3,
		B3,
	}
	ab3: AB3
	err = json.unmarshal_string(`{"name": "x", "n": "y"}`, &ab3)
	b3, is_b3 := ab3.(B3)
	testing.expectf(t, err == nil && is_b3 && b3 == {"x", "y"}, "%v %v", ab3, err)
	delete(b3.name)
	delete(b3.n)

	for n in 0..<64 {
		f := Failing_Allocator{backing = context.temp_allocator, left = n}
		got: AB3
		ferr := json.unmarshal_string(`{"name": "x", "n": "y"}`, &got, allocator = failing_allocator(&f))
		if ferr == nil {
			got_b, got_is_b := got.(B3)
			testing.expectf(t, got_is_b && got_b == {"x", "y"}, "with %d allocations: %v", n, got)
			break
		}
		testing.expectf(t, ferr == json.Error.Out_Of_Memory, "with %d allocations: %v", n, ferr)
	}

	P :: struct {
		x: int,
	}
	Q :: struct {
		y: int,
	}
	none := Failing_Allocator{backing = context.allocator}
	pq: union{P, Q}
	err = json.unmarshal_string(`{"y": 1}`, &pq, allocator = failing_allocator(&none))
	q, is_q := pq.(Q)
	testing.expectf(t, err == nil && is_q && q.y == 1, "%v %v", pq, err)
	wide: union{i8, i64}
	err = json.unmarshal_string(`300`, &wide, allocator = failing_allocator(&none), flags = {.Disallow_Integer_Wrap})
	testing.expectf(t, err == nil && wide == i64(300), "%v %v", wide, err)

	Flat :: struct {
		arr:   [2]i8,
		en:    [Nest_Key]u8,
		inner: union{u8, Q},
		bits:  bit_set[0..<8],
		f:     f32,
		ok:    bool,
	}
	flat: union{P, Flat}
	err = json.unmarshal_string(`{"arr": [1, 2], "en": {"A": 3}, "inner": {"y": 4}, "bits": 5, "f": 0.5, "ok": true}`, &flat, allocator = failing_allocator(&none))
	fl, is_flat := flat.(Flat)
	testing.expectf(t, err == nil && is_flat && fl.arr == {1, 2} && fl.en[.A] == 3 && fl.inner == Q{4} && fl.bits == {0, 2} && fl.f == 0.5 && fl.ok, "%v %v", flat, err)
}

@(test)
review_unmarshal_union_nested_fit :: proc(t: ^testing.T) {
	IA :: struct {
		a: int,
	}
	IB :: struct {
		a, b: int,
	}
	X :: struct {
		inner: IA,
	}
	Y :: struct {
		inner: IB,
	}
	xy: union{X, Y}
	err := json.unmarshal_string(`{"inner": {"a": 1, "b": 2}}`, &xy)
	y, is_y := xy.(Y)
	testing.expectf(t, err == nil && is_y && y.inner == {1, 2}, "%v %v", xy, err)

	XS :: struct {
		inner: IA,
		s:     string,
	}
	YS :: struct {
		inner: IB,
		s:     string,
	}
	xys: union{XS, YS}
	err = json.unmarshal_string(`{"inner": {"a": 1, "b": 2}, "s": "q"}`, &xys)
	ys, is_ys := xys.(YS)
	testing.expectf(t, err == nil && is_ys && ys.inner == {1, 2} && ys.s == "q", "%v %v", xys, err)
	delete(ys.s)

	Inner :: union {
		IA,
		IB,
	}
	W :: struct {
		u: Inner,
		s: string,
	}
	ws: []union{W, int}
	err = json.unmarshal_string(`[{"u": {"a": 1, "b": 2}, "s": "q"}, 3, {"u": {"a": 4}, "s": ""}]`, &ws)
	testing.expectf(t, err == nil && len(ws) == 3, "%v %v", ws, err)
	if len(ws) == 3 {
		w0, w0_ok := ws[0].(W)
		w2, w2_ok := ws[2].(W)
		testing.expectf(t, w0_ok && w0.u == IB{1, 2} && w0.s == "q" && ws[1] == 3 && w2_ok && w2.u == IA{4}, "%v", ws)
		delete(w0.s)
		delete(w2.s)
	}
	delete(ws)

	After :: struct {
		u: Inner,
		x: int,
	}
	after: After
	err = json.unmarshal_string(`{"u": {"a": 1}, "zz": 2, "x": 3}`, &after)
	testing.expectf(t, err == nil && after.u == IA{1} && after.x == 3, "%v %v", after, err)

	Letter :: enum {
		q,
	}
	IE :: struct {
		a: Letter,
	}
	Named :: union {
		IA,
		IE,
	}
	Holder :: struct {
		u: Named,
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	held: union{Holder, int}
	err = json.unmarshal_string(`{"u": {"a": "q"}}`, &held, allocator = mem.tracking_allocator(&track))
	h, is_h := held.(Holder)
	testing.expectf(t, err == nil && is_h && h.u == IE{.q}, "%v %v", held, err)
	testing.expectf(t, len(track.allocation_map) == 0, "leaked %v", len(track.allocation_map))

	Text :: union {
		int,
		string,
	}
	SX :: struct {
		u: Text,
		x: int,
	}
	SY :: struct {
		u: Text,
		y: int,
	}
	sxy: union{SX, SY}
	err = json.unmarshal_string(`{"u": "hello", "y": 1}`, &sxy, allocator = mem.tracking_allocator(&track))
	sy, is_sy := sxy.(SY)
	testing.expectf(t, err == nil && is_sy && sy.u == "hello" && sy.y == 1, "%v %v", sxy, err)
	if text, is_text := sy.u.(string); is_text {
		delete(text, mem.tracking_allocator(&track))
	}
	testing.expectf(t, len(track.allocation_map) == 0, "leaked %v", len(track.allocation_map))
}

@(test)
review_unmarshal_map_value_error_keeps_value :: proc(t: ^testing.T) {
	V :: struct {
		a: string,
		b: int,
	}
	m: map[string]V
	err := json.unmarshal_string(`{"k": {"a": "x", "b": "y"}}`, &m)
	_, unsupported := err.(json.Unsupported_Type_Error)
	testing.expectf(t, unsupported && len(m) == 1 && m["k"].a == "x", "%v %v", m, err)
	if e, is_e := err.(json.Unsupported_Type_Error); is_e {
		delete(e.field)
	}
	for k, val in m {
		delete(k)
		delete(val.a)
	}
	delete(m)
}

@(test)
review_unmarshal_duplicate_keys :: proc(t: ^testing.T) {
	ALLOW :: json.Unmarshal_Flags{.Allow_Duplicate_Fields}
	S :: struct {
		m: map[string]int,
		a: []int,
		s: string,
	}
	free_s :: proc(s: ^S, allocator: runtime.Allocator) {
		for k in s.m {
			delete(k, allocator)
		}
		delete(s.m)
		delete(s.a, allocator)
		delete(s.s, allocator)
		s^ = {}
	}
	free_strings :: proc(m: ^map[string]string, allocator: runtime.Allocator) {
		for k, v in m {
			delete(k, allocator)
			delete(v, allocator)
		}
		delete(m^)
		m^ = nil
	}
	E :: enum {
		A,
		B,
	}
	Big :: enum {
		Lo = 0,
		Hi = 1000,
	}

	for spec in SPECS {
		DUPS :: `{"m": {"a": 1}, "m": {"b": 2}, "a": [1, 2, 3], "a": [9], "s": "x", "s": null}`
		s: S
		err := json.unmarshal_string(DUPS, &s, spec)
		testing.expectf(t, err == json.Unmarshal_Data_Error.Multiple_Use_Field, "%v: %v", spec, err)
		free_s(&s, context.allocator)
		err = json.unmarshal_string(DUPS, &s, spec, flags = ALLOW)
		testing.expectf(t, err == nil && len(s.m) == 1 && s.m["b"] == 2 && len(s.a) == 1 && s.a[0] == 9 && s.s == "", "%v: %v %v", spec, s, err)
		free_s(&s, context.allocator)

		m: map[string]string
		err = json.unmarshal_string(`{"a": "x", "b": "z", "a": "y"}`, &m, spec)
		testing.expectf(t, err == json.Unmarshal_Data_Error.Multiple_Use_Field && m["a"] == "x", "%v: %v %v", spec, m, err)
		free_strings(&m, context.allocator)
		err = json.unmarshal_string(`{"a": "x", "b": "z", "a": "y"}`, &m, spec, flags = ALLOW)
		testing.expectf(t, err == nil && len(m) == 2 && m["a"] == "y" && m["b"] == "z", "%v: %v %v", spec, m, err)
		free_strings(&m, context.allocator)

		for flags in ([]json.Unmarshal_Flags{{}, ALLOW}) {
			m[strings.clone("a")] = strings.clone("old")
			old := m["a"]
			err = json.unmarshal_string(`{"a": "new", "c": "w"}`, &m, spec, flags = flags)
			testing.expectf(t, err == nil && len(m) == 2 && m["a"] == "new" && m["c"] == "w", "%v %v: %v %v", spec, flags, m, err)
			delete(old)
			err = json.unmarshal_string(`{"d": "1", "d": "2"}`, &m, spec, flags = flags)
			if flags == {} {
				testing.expectf(t, err == json.Unmarshal_Data_Error.Multiple_Use_Field && m["d"] == "1", "%v: %v %v", spec, m, err)
			} else {
				testing.expectf(t, err == nil && len(m) == 3 && m["d"] == "2", "%v: %v %v", spec, m, err)
			}
			free_strings(&m, context.allocator)
		}

		XY :: struct {
			x, y: int,
		}
		pm: map[string]XY
		pm["a"] = {1, 2}
		err = json.unmarshal_string(`{"a": {"y": 5}}`, &pm, spec)
		testing.expectf(t, err == nil && len(pm) == 1 && pm["a"] == XY{0, 5}, "%v: %v %v", spec, pm, err)
		delete(pm)

		ea: [E]string
		err = json.unmarshal_string(`{"A": "x", "B": "z", "A": "y"}`, &ea, spec)
		testing.expectf(t, err == json.Unmarshal_Data_Error.Multiple_Use_Field && ea[.A] == "x", "%v: %v %v", spec, ea, err)
		delete(ea[.A])
		delete(ea[.B])
		ea = {}
		err = json.unmarshal_string(`{"A": "x", "B": "z", "A": "y"}`, &ea, spec, flags = ALLOW)
		testing.expectf(t, err == nil && ea[.A] == "y" && ea[.B] == "z", "%v: %v %v", spec, ea, err)
		delete(ea[.A])
		delete(ea[.B])

		big: #sparse[Big]u8
		err = json.unmarshal_string(`{"Lo": 1, "Hi": 2}`, &big, spec)
		testing.expectf(t, err == nil && big[.Lo] == 1 && big[.Hi] == 2, "%v: %v", spec, err)
		err = json.unmarshal_string(`{"Hi": 3, "Hi": 4}`, &big, spec)
		testing.expectf(t, err == json.Unmarshal_Data_Error.Multiple_Use_Field && big[.Hi] == 3, "%v: %v", spec, err)
		err = json.unmarshal_string(`{"Hi": 5, "Hi": 6}`, &big, spec, flags = ALLOW)
		testing.expectf(t, err == nil && big[.Hi] == 6, "%v: %v", spec, err)

		if spec != .JSON {
			im: map[int]int
			err = json.unmarshal_string(`{"16": 1, "0x10": 2}`, &im, spec)
			testing.expectf(t, err == json.Unmarshal_Data_Error.Multiple_Use_Field && im[16] == 1, "%v: %v %v", spec, im, err)
			delete(im)
			im = nil
			err = json.unmarshal_string(`{"16": 1, "0x10": 2, "+16": 3, "7": 4}`, &im, spec, flags = ALLOW)
			testing.expectf(t, err == nil && len(im) == 2 && im[16] == 3 && im[7] == 4, "%v: %v %v", spec, im, err)
			delete(im)
		}
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	DEEP :: `{"m": {"k1": 1, "k2": 2}, "s": "first", "m": {"k3": 3}, "a": [1, 2], "s": "second", "a": [3]}`
	for once in ([]bool{false, true}) {
		for n in 0..<64 {
			f := Failing_Allocator{backing = mem.tracking_allocator(&track), left = n, once = once}
			s: S
			err := json.unmarshal_string(DEEP, &s, allocator = failing_allocator(&f), flags = ALLOW)
			ok := err == nil && len(s.m) == 1 && s.m["k3"] == 3 && s.s == "second" && len(s.a) == 1 && s.a[0] == 3
			testing.expectf(t, ok || err == json.Error.Out_Of_Memory, "%v with %d allocations: %v %v", once, n, s, err)
			free_s(&s, failing_allocator(&f))
			testing.expectf(t, len(track.allocation_map) == 0, "%v with %d allocations: leaked %v", once, n, len(track.allocation_map))
			mem.tracking_allocator_clear(&track)
			if err == nil && !once {
				break
			}
		}
		for n in 0..<64 {
			f := Failing_Allocator{backing = mem.tracking_allocator(&track), left = n, once = once}
			m: map[string]string
			m.allocator = failing_allocator(&f)
			err := json.unmarshal_string(`{"a": "x", "b": "z", "a": "y", "c": "w"}`, &m, allocator = failing_allocator(&f), flags = ALLOW)
			ok := err == nil && len(m) == 3 && m["a"] == "y" && m["b"] == "z" && m["c"] == "w"
			testing.expectf(t, ok || err == json.Error.Out_Of_Memory, "%v with %d allocations: %v %v", once, n, m, err)
			free_strings(&m, failing_allocator(&f))
			testing.expectf(t, len(track.allocation_map) == 0, "%v with %d allocations: leaked %v", once, n, len(track.allocation_map))
			mem.tracking_allocator_clear(&track)
			if err == nil && !once {
				break
			}
		}
		for n in 0..<64 {
			f := Failing_Allocator{backing = mem.tracking_allocator(&track), left = n, once = once}
			m: map[int]string
			m.allocator = failing_allocator(&f)
			err := json.unmarshal_string(`{"1": "x", "2": "z", "1": "y", "3": "w"}`, &m, allocator = failing_allocator(&f), flags = ALLOW)
			ok := err == nil && len(m) == 3 && m[1] == "y" && m[2] == "z" && m[3] == "w"
			testing.expectf(t, ok || err == json.Error.Out_Of_Memory, "%v with %d allocations: %v %v", once, n, m, err)
			for _, v in m {
				delete(v, failing_allocator(&f))
			}
			delete(m)
			testing.expectf(t, len(track.allocation_map) == 0, "%v with %d allocations: leaked %v", once, n, len(track.allocation_map))
			mem.tracking_allocator_clear(&track)
			if err == nil && !once {
				break
			}
		}
	}

	im: map[int]int
	err := json.unmarshal_string(`{"0x10": 1, "16": 2}`, &im, .JSON, context.temp_allocator, ALLOW)
	_, is_type := err.(json.Unsupported_Type_Error)
	testing.expectf(t, is_type, "%v %v", im, err)
}
