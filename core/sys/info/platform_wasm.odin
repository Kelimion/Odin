#+build wasm32, wasm64p32
package sysinfo

@(private)
_ram_stats :: proc "contextless" () -> (total_ram, free_ram, total_swap, free_swap: i64, ok: bool) {
	return
}