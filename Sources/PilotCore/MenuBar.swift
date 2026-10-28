/// The menu-bar icon's text (stories 73 and 36): the focused workspace, a dash while the tiler is not running,
/// ! while secure input hides the keyboard, off while Pilot is switched off. The timer's countdown is its own bar item
/// since card agent-bo-95422911.
public enum MenuBarTitle {
    public static func text(isOn: Bool, workspace: String?, secureInput: Bool) -> String {
        !isOn ? "off" : secureInput ? "\(workspace ?? "–") !" : workspace ?? "–"
    }
}
