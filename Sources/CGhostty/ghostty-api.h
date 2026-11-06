// Pilot's table of the libghostty calls the terminal drop makes (TerminalSurface), one pointer type per call, each taken
// from ghostty.h's own declaration so a signature can never drift from the header. GhosttyAPI fills the table with dlsym
// from the downloaded pack (TerminalPack), and Scripts/build-terminal-pack.sh exports exactly these names from the pack:
// this list is the one both read. ghostty.h stays the tag's, byte for byte (build-ghosttykit.sh compares it).
#include "ghostty.h"

typedef __typeof__(ghostty_app_new) *ghostty_app_new_fn;
typedef __typeof__(ghostty_app_tick) *ghostty_app_tick_fn;
typedef __typeof__(ghostty_config_diagnostics_count) *ghostty_config_diagnostics_count_fn;
typedef __typeof__(ghostty_config_finalize) *ghostty_config_finalize_fn;
typedef __typeof__(ghostty_config_free) *ghostty_config_free_fn;
typedef __typeof__(ghostty_config_get) *ghostty_config_get_fn;
typedef __typeof__(ghostty_config_get_diagnostic) *ghostty_config_get_diagnostic_fn;
typedef __typeof__(ghostty_config_load_default_files) *ghostty_config_load_default_files_fn;
typedef __typeof__(ghostty_config_load_recursive_files) *ghostty_config_load_recursive_files_fn;
typedef __typeof__(ghostty_config_new) *ghostty_config_new_fn;
typedef __typeof__(ghostty_init) *ghostty_init_fn;
typedef __typeof__(ghostty_surface_complete_clipboard_request) *ghostty_surface_complete_clipboard_request_fn;
typedef __typeof__(ghostty_surface_config_new) *ghostty_surface_config_new_fn;
typedef __typeof__(ghostty_surface_free) *ghostty_surface_free_fn;
typedef __typeof__(ghostty_surface_free_text) *ghostty_surface_free_text_fn;
typedef __typeof__(ghostty_surface_ime_point) *ghostty_surface_ime_point_fn;
typedef __typeof__(ghostty_surface_key) *ghostty_surface_key_fn;
typedef __typeof__(ghostty_surface_key_is_binding) *ghostty_surface_key_is_binding_fn;
typedef __typeof__(ghostty_surface_key_translation_mods) *ghostty_surface_key_translation_mods_fn;
typedef __typeof__(ghostty_surface_mouse_button) *ghostty_surface_mouse_button_fn;
typedef __typeof__(ghostty_surface_mouse_pos) *ghostty_surface_mouse_pos_fn;
typedef __typeof__(ghostty_surface_mouse_scroll) *ghostty_surface_mouse_scroll_fn;
typedef __typeof__(ghostty_surface_new) *ghostty_surface_new_fn;
typedef __typeof__(ghostty_surface_preedit) *ghostty_surface_preedit_fn;
typedef __typeof__(ghostty_surface_process_exited) *ghostty_surface_process_exited_fn;
typedef __typeof__(ghostty_surface_read_text) *ghostty_surface_read_text_fn;
typedef __typeof__(ghostty_surface_set_content_scale) *ghostty_surface_set_content_scale_fn;
typedef __typeof__(ghostty_surface_set_focus) *ghostty_surface_set_focus_fn;
typedef __typeof__(ghostty_surface_set_occlusion) *ghostty_surface_set_occlusion_fn;
typedef __typeof__(ghostty_surface_set_size) *ghostty_surface_set_size_fn;
typedef __typeof__(ghostty_surface_text) *ghostty_surface_text_fn;
