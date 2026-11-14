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
