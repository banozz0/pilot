import Foundation

/// The keyboard's own brightness keys (story 144, card agent-bo-95423314). macOS sends them as system-defined events
/// (NX_SYSDEFINED, CGEventType 14) of subtype 8, NX_SUBTYPE_AUX_CONTROL_BUTTONS, whose data1 holds the key type in its
/// high 16 bits (NX_KEYTYPE_BRIGHTNESS_UP 2, NX_KEYTYPE_BRIGHTNESS_DOWN 3), the state in bits 8 to 15 (0x0A down, 0x0B
/// up) and a repeat in bit 0. The tap takes those two and passes every other system-defined event untouched.
public enum BrightnessKeys {
    /// NX_SYSDEFINED's CGEventType raw value; CGEventType has no case for it.
    public static let eventType: UInt32 = 14
    static let up = 2, down = 3

    public struct Press: Equatable, Sendable {
        public var up: Bool, isDown: Bool, isRepeat: Bool
        public init(up: Bool, isDown: Bool, isRepeat: Bool) { self.up = up; self.isDown = isDown; self.isRepeat = isRepeat }
    }

    /// The brightness key a system-defined event is; nil for every other one (volume, play, eject, the keyboard light).
    public static func press(subtype: Int, data1: Int) -> Press? {
        guard let media = MouseKeys.MediaPress(subtype: subtype, data1: data1), media.keyType == up || media.keyType == down else { return nil }
        return Press(up: media.keyType == up, isDown: media.isDown, isRepeat: media.isRepeat)
    }

    /// What the tap does with each brightness event. The first press decides: taken while Setup › Displays' switch is on
    /// and the target screen has a route (not none, and read), else macOS keeps the key as before. Its repeats and its
    /// key up follow that answer, so a held key asks for the screen once, and a key up never splits from its down.
    public struct Router<Screen> {
        private var held: Screen?

        public init() {}

        /// Whether to take the event, and the screen to step one level on, for a key down. `target` (the screen and its
        /// route, nil when not read) is asked only for a first press with the switch on.
        public mutating func route(_ press: Press, switchOn: Bool,
                                   target: () -> (screen: Screen, route: BrightnessRoute?)?) -> (taken: Bool, step: Screen?) {
            if press.isDown && !press.isRepeat {
                held = nil
                if switchOn, let target = target(), let route = target.route, route != .none { held = target.screen }
            }
            guard let screen = held else { return (false, nil) }
            guard press.isDown else { held = nil; return (true, nil) }
            return (true, screen)
        }
    }
}
