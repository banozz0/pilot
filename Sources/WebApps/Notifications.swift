import Foundation

/// Notifications in a web app (card agent-bo-95422812): WKWebView gives pages no Notification API, so the template
/// adds one (NotificationBridge.script) that posts to the app, which shows macOS notifications as the web app. The
/// first time the site asks, the web app asks Sven, then macOS asks; the answer is kept in the web app's own defaults.
public enum PagePermission: String, Equatable, Sendable { case `default`, granted, denied }

/// What Sven answered for this web app; nil before the site ever asked.
public final class NotificationDecisions {
    public enum Decision: String, Sendable { case allowed, denied }

    private let defaults: UserDefaults
    private static let key = "pilot.notifications.decision", saidKey = "pilot.notifications.macOSOffSaid"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var decision: Decision? {
        get { defaults.string(forKey: Self.key).flatMap(Decision.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: Self.key) }
    }

    /// Whether the macOS-is-off message was shown; it is said once.
    var saidMacOSOff: Bool {
        get { defaults.bool(forKey: Self.saidKey) }
        set { defaults.set(newValue, forKey: Self.saidKey) }
    }

    /// Notification.permission when a page loads.
    public func pagePermission(macOSAllows: Bool) -> PagePermission {
        switch decision {
        case nil: .default
        case .denied?: .denied
        case .allowed?: macOSAllows ? .granted : .denied
        }
    }
}

/// One Notification.requestPermission: Sven's answer first (kept), then macOS's, each asked only when needed.
public struct NotificationGate {
    public struct Answer: Equatable, Sendable {
        public var permission: PagePermission
        /// Said once when macOS has notifications off for the web app.
        public var message: String?
    }

    public static let macOSOff = "Notifications are off for this web app in System Settings › Notifications."

    let decisions: NotificationDecisions
    let askUser: () async -> Bool
    let askMacOS: () async -> Bool

    public init(decisions: NotificationDecisions, askUser: @escaping () async -> Bool, askMacOS: @escaping () async -> Bool) {
        self.decisions = decisions; self.askUser = askUser; self.askMacOS = askMacOS
    }

    /// Runs on the caller's actor (the app's main actor), where the asks are.
    public func request(isolation: isolated (any Actor)? = #isolation) async -> Answer {
        if decisions.decision == nil { decisions.decision = await askUser() ? .allowed : .denied }
        guard decisions.decision == .allowed else { return Answer(permission: .denied) }
        if await askMacOS() { return Answer(permission: .granted) }
        let said = decisions.saidMacOSOff
        decisions.saidMacOSOff = true
        return Answer(permission: .denied, message: said ? nil : Self.macOSOff)
    }
}

/// A message the page's script posts to the app.
public enum WebNotificationMessage: Equatable, Sendable {
    case request(id: Int), show(id: Int, title: String, body: String, tag: String), close(id: Int, tag: String)

    public init?(_ body: Any) {
        guard let body = body as? [String: Any], let id = body["id"] as? Int else { return nil }
        let tag = body["tag"] as? String ?? ""
        switch body["type"] as? String {
        case "request": self = .request(id: id)
        case "show":
            guard let title = body["title"] as? String else { return nil }
            self = .show(id: id, title: title, body: body["body"] as? String ?? "", tag: tag)
        case "close": self = .close(id: id, tag: tag)
        default: return nil
        }
    }

    /// The macOS notification's identifier: a tag replaces the earlier one with the same tag, as browsers do.
    public static func identifier(id: Int, tag: String) -> String { tag.isEmpty ? "id-\(id)" : "tag-\(tag)" }
}

/// The page's Notification API: permission, requestPermission (promise and callback), new Notification(title,
/// {body, tag}) with onclick and close(). It talks to the app's pilotNotification handler; the app answers through
/// window.__pilotNotification.
public enum NotificationBridge {
    public static let handler = "pilotNotification"

    public static func script(permission: PagePermission) -> String {
        """
        (() => {
          const handler = window.webkit?.messageHandlers?.\(handler);
          if (!handler) return;
          let permission = "\(permission.rawValue)";
          const live = new Map(), waiting = new Map();
          // Ids unique across page loads, so a reload never reuses one a delivered notification still carries.
          let next = Date.now() * 1000 + Math.floor(Math.random() * 1000);
          // An event as a browser fires it: to listeners, then to the on<type> property.
          const fire = (n, type, init) => { const e = new Event(type, init); n.dispatchEvent(e); n["on" + type]?.call(n, e); };
          class PilotNotification extends EventTarget {
            constructor(title, options = {}) {
              super();
              this.title = String(title);
              this.body = options.body == null ? "" : String(options.body);
              this.tag = options.tag == null ? "" : String(options.tag);
              this.data = options.data;
              this.onclick = this.onclose = this.onshow = this.onerror = null;
              this._id = next++;
              if (permission !== "granted") { setTimeout(() => fire(this, "error")); return; }
              live.set(this._id, this);
              handler.postMessage({type: "show", id: this._id, title: this.title, body: this.body, tag: this.tag});
              setTimeout(() => fire(this, "show"));
            }
            close() {
              handler.postMessage({type: "close", id: this._id, tag: this.tag});
              if (live.delete(this._id)) fire(this, "close");
            }
            static get permission() { return permission; }
            static requestPermission(callback) {
              return new Promise(resolve => {
                const id = next++;
                waiting.set(id, p => { callback?.(p); resolve(p); });
                handler.postMessage({type: "request", id});
              });
            }
          }
          window.__pilotNotification = {
            resolve(id, p) { permission = p; const done = waiting.get(id); waiting.delete(id); if (done) done(p); },
            click(id) { const n = live.get(id); if (n) fire(n, "click", {cancelable: true}); }
          };
          Object.defineProperty(window, "Notification", {value: PilotNotification, writable: true, configurable: true});
        })();
        """
    }
}
