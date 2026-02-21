package sysinfo

#assert(
	ODIN_ARCH == .amd64   || ODIN_ARCH == .i386      || \
	ODIN_ARCH == .arm32   || ODIN_ARCH == .arm64     || \
	ODIN_ARCH == .wasm32  || ODIN_ARCH == .wasm64p32 || \
	ODIN_ARCH == .riscv64,
	"This package is unsupported on this architecture.")

import "base:runtime"

/*
Retrieves the number of physical and logical CPU cores.

Returns:
- physical: The number of physical cores
- logical:  The number of logical cores
- ok:       `true` when we could retrieve the CPU information, `false` otherwise
*/
cpu_core_count :: proc "contextless" () -> (physical: int, logical: int, ok: bool) {
	return _cpu_core_count()
}

/*
Retrieves CPU features where available.

Returns:
- features: An architecture-specific `bit_set`
- ok:       `true` if we could retrieve the CPU features, `false` otherwise
*/
cpu_features :: proc "contextless" () -> (features: CPU_Features, ok: bool) {
	return _cpu_features()
}

/*
Retrieves the CPU's name.

*Allocates Using Provided Allocator*

Input:
- allocator: a `runtime.Allocator`

Returns:
- name: A cloned `string` containing the CPU model name. "" if failed
- err:  An optional `runtime.Allocator_Error`
*/
cpu_name :: proc(allocator: runtime.Allocator) -> (name: string, err: runtime.Allocator_Error) #optional_allocator_error {
	return _cpu_name(allocator)
}


os_version: OS_Version
ram:        RAM
gpus:       []GPU

// Only on MacOS, contains the actual MacOS version, while the `os_version` contains the kernel version.
macos_version: Version

OS_Version_Platform :: enum {
	Unknown,
	Windows,
	Linux,
	MacOS,
	iOS,
	FreeBSD,
	OpenBSD,
	NetBSD,
}

Version :: struct {
	major, minor, patch: int,
}

OS_Version :: struct {
	platform: OS_Version_Platform,

	using _:   Version,
	build:     [2]int,
	version:   string,

	as_string: string,
}

RAM :: struct {
	total_ram:  int,
	free_ram:   int,
	total_swap: int,
	free_swap:  int,
}

GPU :: struct {
	vendor_name: string,
	model_name:  string,
	total_ram:   int,
}

@(private)
version_string_buf: [1024]u8

@(private)
MAX_GPUS :: 16

@(private)
_gpus: [MAX_GPUS]GPU

@(private)
_gpu_string_buf: [MAX_GPUS * 256 * 2]u8 // Reserve up to 256 bytes for each GPU's vendor and model name

@(private)
_gpu_string_offset: int

@(private)
intern_gpu_string :: proc "contextless" (str: string) -> (res: string, ok: bool) {
	if _gpu_string_offset + len(str) + 1 > size_of(_gpu_string_buf) {
		return "", false
	}

	n := copy(_gpu_string_buf[_gpu_string_offset:], str)
	_gpu_string_buf[_gpu_string_offset + len(str)] = 0
	res = string(_gpu_string_buf[_gpu_string_offset:][:len(str)])
	_gpu_string_offset += n + 1

	return res, true
}