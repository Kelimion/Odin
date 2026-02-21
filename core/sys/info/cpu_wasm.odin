#+build wasm32, wasm64p32
package sysinfo

import "base:runtime"

@(private)
_cpu_core_count :: proc "contextless" () -> (physical: int, logical: int, ok: bool) {
	return 0, 0, false
}

CPU_Feature  :: enum u64 {}
CPU_Features :: distinct bit_set[CPU_Feature; u64]

@(private)
_cpu_features :: proc "contextless" () -> (features: CPU_Features, ok: bool) {
	return {}, false
}

@(private)
_cpu_name :: proc(allocator: runtime.Allocator, loc := #caller_location) -> (name: string, err: runtime.Allocator_Error) #optional_allocator_error {
	name = "wasm32" when ODIN_ARCH == .wasm32 else "wasm64p32"
	data := allocator.procedure(allocator.data, .Alloc, len(name), 1, nil, 0, loc) or_return
	copy(data, name)
	return string(data), nil
}