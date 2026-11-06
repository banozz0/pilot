import CGhostty
import Darwin

/// The libghostty calls TerminalSurface makes, looked up by name in the downloaded pack (T76): Pilot links no libghostty,
/// so a pack fetched after launch loads without a relaunch, which weak linking could not do. Each pointer's type is
/// ghostty.h's own declaration (ghostty-api.h), and a pack missing any call is refused whole. Named as the C calls without
/// their `ghostty_` prefix: `api.surface_key` is `ghostty_surface_key`.
struct GhosttyAPI: @unchecked Sendable {
    let app_new: ghostty_app_new_fn
    let app_tick: ghostty_app_tick_fn
    let config_diagnostics_count: ghostty_config_diagnostics_count_fn
    let config_finalize: ghostty_config_finalize_fn
    let config_free: ghostty_config_free_fn
    let config_get: ghostty_config_get_fn
    let config_get_diagnostic: ghostty_config_get_diagnostic_fn
    let config_load_default_files: ghostty_config_load_default_files_fn
    let config_load_recursive_files: ghostty_config_load_recursive_files_fn
    let config_new: ghostty_config_new_fn
    let initialize: ghostty_init_fn
    let surface_complete_clipboard_request: ghostty_surface_complete_clipboard_request_fn
    let surface_config_new: ghostty_surface_config_new_fn
    let surface_free: ghostty_surface_free_fn
    let surface_free_text: ghostty_surface_free_text_fn
    let surface_ime_point: ghostty_surface_ime_point_fn
    let surface_key: ghostty_surface_key_fn
    let surface_key_is_binding: ghostty_surface_key_is_binding_fn
    let surface_key_translation_mods: ghostty_surface_key_translation_mods_fn
    let surface_mouse_button: ghostty_surface_mouse_button_fn
    let surface_mouse_pos: ghostty_surface_mouse_pos_fn
    let surface_mouse_scroll: ghostty_surface_mouse_scroll_fn
    let surface_new: ghostty_surface_new_fn
    let surface_preedit: ghostty_surface_preedit_fn
    let surface_process_exited: ghostty_surface_process_exited_fn
    let surface_read_text: ghostty_surface_read_text_fn
    let surface_set_content_scale: ghostty_surface_set_content_scale_fn
    let surface_set_focus: ghostty_surface_set_focus_fn
    let surface_set_occlusion: ghostty_surface_set_occlusion_fn
    let surface_set_size: ghostty_surface_set_size_fn
    let surface_text: ghostty_surface_text_fn

    /// Every call from `handle`, a dlopen of the pack; throws naming the first one missing.
    init(handle: UnsafeMutableRawPointer) throws {
        func call<T>(_ name: String) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw TerminalPack.Failure("The terminal pack has no \(name)") }
            return unsafeBitCast(pointer, to: T.self)
        }
        app_new = try call("ghostty_app_new")
        app_tick = try call("ghostty_app_tick")
        config_diagnostics_count = try call("ghostty_config_diagnostics_count")
        config_finalize = try call("ghostty_config_finalize")
        config_free = try call("ghostty_config_free")
        config_get = try call("ghostty_config_get")
        config_get_diagnostic = try call("ghostty_config_get_diagnostic")
        config_load_default_files = try call("ghostty_config_load_default_files")
        config_load_recursive_files = try call("ghostty_config_load_recursive_files")
        config_new = try call("ghostty_config_new")
        initialize = try call("ghostty_init")
        surface_complete_clipboard_request = try call("ghostty_surface_complete_clipboard_request")
        surface_config_new = try call("ghostty_surface_config_new")
        surface_free = try call("ghostty_surface_free")
        surface_free_text = try call("ghostty_surface_free_text")
        surface_ime_point = try call("ghostty_surface_ime_point")
        surface_key = try call("ghostty_surface_key")
        surface_key_is_binding = try call("ghostty_surface_key_is_binding")
        surface_key_translation_mods = try call("ghostty_surface_key_translation_mods")
        surface_mouse_button = try call("ghostty_surface_mouse_button")
        surface_mouse_pos = try call("ghostty_surface_mouse_pos")
        surface_mouse_scroll = try call("ghostty_surface_mouse_scroll")
        surface_new = try call("ghostty_surface_new")
        surface_preedit = try call("ghostty_surface_preedit")
        surface_process_exited = try call("ghostty_surface_process_exited")
        surface_read_text = try call("ghostty_surface_read_text")
        surface_set_content_scale = try call("ghostty_surface_set_content_scale")
        surface_set_focus = try call("ghostty_surface_set_focus")
        surface_set_occlusion = try call("ghostty_surface_set_occlusion")
        surface_set_size = try call("ghostty_surface_set_size")
        surface_text = try call("ghostty_surface_text")
    }
}
