@testable import PilotCore

/// The block as Pilot wrote it at the end of ~/.aerospace.toml until 2026-10-10 (R3, ADR 0011): what the one-time
/// import (`PilotBlock.carryOver`) reads back from a file Pilot once wrote.
extension PilotBlock {
    static let begin = "# >>> Pilot block: written from Pilot's settings, edits here are overwritten >>>"
    static let end = "# <<< Pilot block <<<"

    /// The block, markers included, without a trailing newline.
    var toml: String {
        let inner = gapsOn ? gaps.inner : 0, outer = gapsOn ? gaps.outer : 0
        let top = topBar.isEmpty ? "\(outer)"
            : "[" + (topBar.map { "{ monitor.\(Self.quote(NameList.pattern([$0.monitor]))) = \(outer + $0.height) }" } + ["\(outer)"]).joined(separator: ", ") + "]"
        let gapLines = [("inner.horizontal", "\(inner)"), ("inner.vertical", "\(inner)"), ("outer.left", "\(outer)"), ("outer.bottom", "\(outer)"),
                        ("outer.top", top), ("outer.right", "\(outer)")]
        var sections = ["[gaps]\n" + gapLines.map { "    \($0) = \($1)" }.joined(separator: "\n")]
        func callback(_ condition: String, _ value: String, _ run: String) -> String {
            "[[on-window-detected]]\n    if.\(condition) = \(Self.quote(value))\n    run = \(Self.quote(run))"
        }
        sections += rules.map { callback("app-id", $0.appId, "move-node-to-workspace " + $0.workspace) }
        for (condition, list) in [("app-name-regex-substring", floatApps), ("window-title-regex-substring", floatTitles)] where !list.isEmpty {
            sections.append(callback(condition, NameList.pattern(list), "layout floating"))
        }
        return ([Self.begin] + sections + [Self.end]).joined(separator: "\n\n")
    }

    /// A basic string: backslashes and double quotes escaped.
    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Sven's ~/.aerospace.toml as it was on 2026-10-04, cut into the parts milestone C's dotfiles edit keeps or moves:
/// his gaps and his rules move into the Pilot block, the rest stays byte for byte. Each part ends in a newline.
enum SvenConfig {
    static let head = #"""
# AeroSpace — tiling and workspaces since 2026-10-04 (Pilot spike, Sven's yes).
# Source of truth: dotfiles/workstation/aerospace/aerospace.toml (symlinked to ~/.aerospace.toml).
# Replaces yabai + skhd (stopped and disabled, not uninstalled). Restart them with:
#   launchctl enable gui/$(id -u)/com.asmvik.yabai; launchctl enable gui/$(id -u)/com.koekeishiya.skhd
#   yabai --start-service; skhd --start-service
#
# Modifier: Hyper = Caps held = cmd+ctrl+alt (Karabiner). Plain Alt stays free for typing.
# Same letters as the old left-Alt skhd binds wherever Hammerspoon's Hyper tier allowed it;
# where Hyper+<key> is a daily Hammerspoon bind (S screenshot, G Ghostex, D Shottr, B Zen,
# F Finder, Space Vicinae) the AeroSpace bind moved to a free key instead.

config-version = 2
start-at-login = true
after-startup-command = []
auto-reload-config = true

enable-normalization-flatten-containers = true
enable-normalization-opposite-orientation-for-nested-containers = true
accordion-padding = 30
default-root-container-layout = 'tiles'
default-root-container-orientation = 'auto'

# yabai had mouse_follows_focus off.
on-focused-monitor-changed = []
automatically-unhide-macos-hidden-apps = false
persistent-workspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
focus-follows-mouse.enabled = false
key-mapping.preset = 'qwerty'


"""#
    static let gaps = #"""
# yabai: 24px outer border, 10px gutter.
gaps.inner.horizontal = 10
gaps.inner.vertical   = 10
gaps.outer.left       = 24
gaps.outer.bottom     = 24
gaps.outer.top        = 24
gaps.outer.right      = 24


"""#
    static let binds = #"""
[mode.main.binding]
    # Hammerspoon gave up Hyper+K/L and Hyper+Shift+HJKL for these (commit 82b142c).
    # focus (yabai lalt-hjkl)
    cmd-ctrl-alt-h = 'focus left'
    cmd-ctrl-alt-j = 'focus down'
    cmd-ctrl-alt-k = 'focus up'
    cmd-ctrl-alt-l = 'focus right'
    # focus ring (yabai lalt-tab)
    cmd-ctrl-alt-tab       = 'focus dfs-next --boundaries-action wrap-around-the-workspace'
    cmd-ctrl-alt-shift-tab = 'focus dfs-prev --boundaries-action wrap-around-the-workspace'
    # move (yabai shift-lalt-hjkl swap)
    cmd-ctrl-alt-shift-h = 'move left'
    cmd-ctrl-alt-shift-j = 'move down'
    cmd-ctrl-alt-shift-k = 'move up'
    cmd-ctrl-alt-shift-l = 'move right'
    # resize (yabai ctrl-lalt-hjkl, 40px)
    cmd-ctrl-alt-minus = 'resize smart -40'
    cmd-ctrl-alt-equal = 'resize smart +40'
    # workspaces
    cmd-ctrl-alt-1 = 'workspace 1'
    cmd-ctrl-alt-2 = 'workspace 2'
    cmd-ctrl-alt-3 = 'workspace 3'
    cmd-ctrl-alt-4 = 'workspace 4'
    cmd-ctrl-alt-5 = 'workspace 5'
    cmd-ctrl-alt-6 = 'workspace 6'
    cmd-ctrl-alt-7 = 'workspace 7'
    cmd-ctrl-alt-8 = 'workspace 8'
    cmd-ctrl-alt-9 = 'workspace 9'
    cmd-ctrl-alt-shift-1 = 'move-node-to-workspace 1'
    cmd-ctrl-alt-shift-2 = 'move-node-to-workspace 2'
    cmd-ctrl-alt-shift-3 = 'move-node-to-workspace 3'
    cmd-ctrl-alt-shift-4 = 'move-node-to-workspace 4'
    cmd-ctrl-alt-shift-5 = 'move-node-to-workspace 5'
    cmd-ctrl-alt-shift-6 = 'move-node-to-workspace 6'
    cmd-ctrl-alt-shift-7 = 'move-node-to-workspace 7'
    cmd-ctrl-alt-shift-8 = 'move-node-to-workspace 8'
    cmd-ctrl-alt-shift-9 = 'move-node-to-workspace 9'
    cmd-ctrl-alt-backtick = 'workspace-back-and-forth'
    # displays (yabai lalt-s / lalt-g; Hyper+S/G are Shottr and Ghostex)
    cmd-ctrl-alt-comma        = 'focus-monitor --wrap-around left'
    cmd-ctrl-alt-period       = 'focus-monitor --wrap-around right'
    cmd-ctrl-alt-shift-comma  = 'move-node-to-monitor --focus-follows-window --wrap-around left'
    cmd-ctrl-alt-shift-period = 'move-node-to-monitor --focus-follows-window --wrap-around right'
    # layout (yabai lalt-d split, lalt-f zoom, lalt-space float)
    cmd-ctrl-alt-slash   = 'layout tiles horizontal vertical'
    cmd-ctrl-alt-shift-f = 'fullscreen'
    cmd-ctrl-alt-shift-t = 'layout floating tiling'
    # escape hatch (yabai shift-lalt-r restart)
    cmd-ctrl-alt-shift-r = 'reload-config'
    cmd-ctrl-alt-shift-semicolon = 'mode service'

# Hyper+Shift+; then one key.
[mode.service.binding]
    esc = ['reload-config', 'mode main']
    r = ['flatten-workspace-tree', 'mode main']
    b = ['balance-sizes', 'mode main']
    f = ['layout floating tiling', 'mode main']
    h = ['swap left', 'mode main']
    j = ['swap down', 'mode main']
    k = ['swap up', 'mode main']
    l = ['swap right', 'mode main']
    shift-h = ['join-with left', 'mode main']
    shift-j = ['join-with down', 'mode main']
    shift-k = ['join-with up', 'mode main']
    shift-l = ['join-with right', 'mode main']
    backspace = ['close-all-windows-but-current', 'mode main']

"""#
    static let rules = #"""

# ── app rules: Ghostty on 1, Zen on 2 ────────────────────────────────────────
[[on-window-detected]]
    if.app-id = 'com.mitchellh.ghostty'
    run = 'move-node-to-workspace 1'

[[on-window-detected]]
    if.app-id = 'app.zen-browser.zen'
    run = 'move-node-to-workspace 2'

# ── never tile: yabai's manage=off list ──────────────────────────────────────
# Finder tiles here on purpose (yabai floated it); add it below to float it again.
[[on-window-detected]]
    if.app-name-regex-substring = '^(Vicinae|Shottr|Stats|CodexBar|Reminders MenuBar|Bitwarden|Tailscale|FluidVoice|Fastpotify|CuaDriver|System Settings|System Information|Calculator|Installer|Archive Utility|Karabiner-Elements|Karabiner-EventViewer|Simulator)$'
    run = 'layout floating'

[[on-window-detected]]
    if.window-title-regex-substring = '^(Preferences|Settings|MiniPlayer)$'
    run = 'layout floating'

"""#
    /// The file today: gaps and rules outside any block.
    static let today = head + gaps + binds + rules
    /// The file once the dotfiles edit took the gaps and rules out, before Pilot writes its block.
    static let migrated = head + binds
}
