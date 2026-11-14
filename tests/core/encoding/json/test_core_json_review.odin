package test_core_json

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import "base:runtime"

Failing_Allocator :: struct {
	backing: runtime.Allocator,
	left:    int,
}

failing_allocator_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	f := (^Failing_Allocator)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if f.left <= 0 {
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
		testing.expectf(t, err == json.Error.Max_Depth_Exceeded && track.total_allocation_count == 0, "%v: %v after %d allocations", flags, err, track.total_allocation_count)
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
	for src in ([]string{`[0e]`, `[01]`, `[-01]`, `[1e+]`, "[\"a\x01b\"]", `["a`, `['a`, `["\uZZZZ"]`, `['\ug000']`}) {
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
	for src in ([]string{"{\"a\x01\":1}", `{"\uZZZZ":1}`, `{"a":1e}`, `{"a":{"b":01}}`}) {
		for spec in SPECS {
			expect_document(t, src, spec, false)
		}
	}
	expect_document(t, `{"\q":1}`, .JSON, false)
	expect_document(t, `{'a':1}`, .JSON, false)
	expect_document(t, `{'a':1}`, .JSON5, true)

	for spec in SPECS {
		for src in ([]string{"", "[", "[1", "[1,", "[@]", `{"a":`}) {
			v, err := json.parse_string(src, spec)
			testing.expectf(t, err == .Unexpected_Token && v == nil, "%v %q: %v, %v", spec, src, v, err)
		}
		unclosed, unclosed_err := json.parse_string(`{"a":1`, spec)
		want: json.Error = .Unexpected_Token if spec == .JSON else .Expected_String_For_Object_Key
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
		testing.expectf(t, err == nil && len(m) == 1, "%v: %v, %v", spec, m, err)
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
