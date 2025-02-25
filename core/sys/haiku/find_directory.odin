#+build haiku
package sys_haiku

import "base:intrinsics"

foreign import libroot "system:c"

directory_which :: enum i32 {
	// Per volume directories
	DESKTOP_DIRECTORY = 0,
	TRASH_DIRECTORY,

	// System directories
	SYSTEM_DIRECTORY        = 1000,
	SYSTEM_ADDONS_DIRECTORY = 1002,
	SYSTEM_BOOT_DIRECTORY,
	SYSTEM_FONTS_DIRECTORY,
	SYSTEM_LIB_DIRECTORY,
	SYSTEM_SERVERS_DIRECTORY,
	SYSTEM_APPS_DIRECTORY,
	SYSTEM_BIN_DIRECTORY,
	SYSTEM_DOCUMENTATION_DIRECTORY = 1010,
	SYSTEM_PREFERENCES_DIRECTORY,
	SYSTEM_TRANSLATORS_DIRECTORY,
	SYSTEM_MEDIA_NODES_DIRECTORY,
	SYSTEM_SOUNDS_DIRECTORY,
	SYSTEM_DATA_DIRECTORY,
	SYSTEM_DEVELOP_DIRECTORY,
	SYSTEM_PACKAGES_DIRECTORY,
	SYSTEM_HEADERS_DIRECTORY,
	SYSTEM_ETC_DIRECTORY      = 2008,
	SYSTEM_SETTINGS_DIRECTORY = 2010,
	SYSTEM_LOG_DIRECTORY      = 2012,
	SYSTEM_SPOOL_DIRECTORY,
	SYSTEM_TEMP_DIRECTORY,
	SYSTEM_VAR_DIRECTORY,
	SYSTEM_CACHE_DIRECTORY       = 2020,
	SYSTEM_NONPACKAGED_DIRECTORY = 2023,
	SYSTEM_NONPACKAGED_ADDONS_DIRECTORY,
	SYSTEM_NONPACKAGED_TRANSLATORS_DIRECTORY,
	SYSTEM_NONPACKAGED_MEDIA_NODES_DIRECTORY,
	SYSTEM_NONPACKAGED_BIN_DIRECTORY,
	SYSTEM_NONPACKAGED_DATA_DIRECTORY,
	SYSTEM_NONPACKAGED_FONTS_DIRECTORY,
	SYSTEM_NONPACKAGED_SOUNDS_DIRECTORY,
	SYSTEM_NONPACKAGED_DOCUMENTATION_DIRECTORY,
	SYSTEM_NONPACKAGED_LIB_DIRECTORY,
	SYSTEM_NONPACKAGED_HEADERS_DIRECTORY,
	SYSTEM_NONPACKAGED_DEVELOP_DIRECTORY,

	// User directories. These are interpreted in the context of the user making the find_directory call.
	USER_DIRECTORY = 3000,
	USER_CONFIG_DIRECTORY,
	USER_ADDONS_DIRECTORY,
	USER_BOOT_DIRECTORY,
	USER_FONTS_DIRECTORY,
	USER_LIB_DIRECTORY,
	USER_SETTINGS_DIRECTORY,
	USER_DESKBAR_DIRECTORY,
	USER_PRINTERS_DIRECTORY,
	USER_TRANSLATORS_DIRECTORY,
	USER_MEDIA_NODES_DIRECTORY,
	USER_SOUNDS_DIRECTORY,
	USER_DATA_DIRECTORY,
	USER_CACHE_DIRECTORY,
	USER_PACKAGES_DIRECTORY,
	USER_HEADERS_DIRECTORY,
	USER_NONPACKAGED_DIRECTORY,
	USER_NONPACKAGED_ADDONS_DIRECTORY,
	USER_NONPACKAGED_TRANSLATORS_DIRECTORY,
	USER_NONPACKAGED_MEDIA_NODES_DIRECTORY,
	USER_NONPACKAGED_BIN_DIRECTORY,
	USER_NONPACKAGED_DATA_DIRECTORY,
	USER_NONPACKAGED_FONTS_DIRECTORY,
	USER_NONPACKAGED_SOUNDS_DIRECTORY,
	USER_NONPACKAGED_DOCUMENTATION_DIRECTORY,
	USER_NONPACKAGED_LIB_DIRECTORY,
	USER_NONPACKAGED_HEADERS_DIRECTORY,
	USER_NONPACKAGED_DEVELOP_DIRECTORY,
	USER_DEVELOP_DIRECTORY,
	USER_DOCUMENTATION_DIRECTORY,
	USER_SERVERS_DIRECTORY,
	USER_APPS_DIRECTORY,
	USER_BIN_DIRECTORY,
	USER_PREFERENCES_DIRECTORY,
	USER_ETC_DIRECTORY,
	USER_LOG_DIRECTORY,
	USER_SPOOL_DIRECTORY,
	USER_VAR_DIRECTORY,

	// Global directories
	APPS_DIRECTORY = 4000,
	PREFERENCES_DIRECTORY,
	UTILITIES_DIRECTORY,
	PACKAGE_LINKS_DIRECTORY,

	// Obsolete: Legacy BeOS definition to be phased out
	BEOS_DIRECTORY = 1000,
	BEOS_SYSTEM_DIRECTORY,
	BEOS_ADDONS_DIRECTORY,
	BEOS_BOOT_DIRECTORY,
	BEOS_FONTS_DIRECTORY,
	BEOS_LIB_DIRECTORY,
	BEOS_SERVERS_DIRECTORY,
	BEOS_APPS_DIRECTORY,
	BEOS_BIN_DIRECTORY,
	BEOS_ETC_DIRECTORY,
	BEOS_DOCUMENTATION_DIRECTORY,
	BEOS_PREFERENCES_DIRECTORY,
	BEOS_TRANSLATORS_DIRECTORY,
	BEOS_MEDIA_NODES_DIRECTORY,
	BEOS_SOUNDS_DIRECTORY,
}

find_path_flag :: enum u32 {
	CREATE_DIRECTORY        = intrinsics.constant_log2(0x0001),
	CREATE_PARENT_DIRECTORY = intrinsics.constant_log2(0x0002),
	EXISTING_ONLY           = intrinsics.constant_log2(0x0004),
	
	// find_paths() only
	SYSTEM_ONLY             = intrinsics.constant_log2(0x0010),
	USER_ONLY               = intrinsics.constant_log2(0x0020),
}
find_path_flags :: distinct bit_set[find_path_flag; u32]

path_base_directory :: enum i32 {
	INSTALLATION_LOCATION_DIRECTORY,
	ADD_ONS_DIRECTORY,
	APPS_DIRECTORY,
	BIN_DIRECTORY,
	BOOT_DIRECTORY,
	CACHE_DIRECTORY,
	DATA_DIRECTORY,
	DEVELOP_DIRECTORY,
	DEVELOP_LIB_DIRECTORY,
	DOCUMENTATION_DIRECTORY,
	ETC_DIRECTORY,
	FONTS_DIRECTORY,
	HEADERS_DIRECTORY,
	LIB_DIRECTORY,
	LOG_DIRECTORY,
	MEDIA_NODES_DIRECTORY,
	PACKAGES_DIRECTORY,
	PREFERENCES_DIRECTORY,
	SERVERS_DIRECTORY,
	SETTINGS_DIRECTORY,
	SOUNDS_DIRECTORY,
	SPOOL_DIRECTORY,
	TRANSLATORS_DIRECTORY,
	VAR_DIRECTORY,

	// find_path() only
	IMAGE_PATH = 1000,
	PACKAGE_PATH,
}

// value that can be used instead of a pointer to a symbol in the program image
APP_IMAGE_SYMBOL :: rawptr(addr_t(0))
// pointer to a symbol in the callers image (same as B_CURRENT_IMAGE_SYMBOL)
current_image_symbol :: proc "contextless" () -> rawptr { return rawptr(current_image_symbol) }

@(default_calling_convention="c")
foreign libroot {
	find_directory         :: proc(which: directory_which, volume: dev_t, createIt: bool, pathString: [^]byte, length: i32) -> status_t ---
	find_path              :: proc(codePointer: rawptr, baseDirectory: path_base_directory, subPath: cstring, pathBuffer: [^]byte, bufferSize: uint) -> status_t ---
	find_path_etc          :: proc(codePointer: rawptr, dependency: cstring, architecture: cstring, baseDirectory: path_base_directory, subPath: cstring, flags: find_path_flags, pathBuffer: [^]byte, bufferSize: uint) -> status_t ---
	find_path_for_path     :: proc(path: cstring, baseDirectory: path_base_directory, subPath: cstring, pathBuffer: [^]byte, bufferSize: uint) -> status_t ---
	find_path_for_path_etc :: proc(path: cstring, dependency: cstring, architecture: cstring, baseDirectory: path_base_directory, subPath: cstring, flags: find_path_flags, pathBuffer: [^]byte, bufferSize: uint) -> status_t ---
	find_paths             :: proc(baseDirectory: path_base_directory, subPath: cstring, _paths: ^[^][^]byte, _pathCount: ^uint) -> status_t ---
	find_paths_etc         :: proc(architecture: cstring, baseDirectory: path_base_directory, subPath: cstring, flags: find_path_flags, _paths: ^[^][^]byte, _pathCount: ^uint) -> status_t ---
}
