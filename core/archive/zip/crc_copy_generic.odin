#+build !amd64
#+build !arm64
package archive_zip

import "core:hash"

@(private)
_crc32_copy :: proc "contextless" (dst, src: []u8, seed: u32) -> u32 {
	copy(dst[:len(src)], src)
	return hash.crc32(src, seed)
}
