import AppKit
import PilotCore

/// Pastes a sticker into the app in front (card agent-bo-95423130): the picture goes on the pasteboard alone, Cmd+V
/// pastes it, and a second later the pasteboard gets back what Sven had copied, unless he copied something since.
@MainActor
enum StickerPaster {
    /// How long the app in front has to read the picture before the pasteboard is given back.
    static let restoreAfter: Duration = .seconds(1)

    static func paste(_ sticker: Sticker, on board: NSPasteboard = .general) {
        let saved = PasteboardSnapshot(board)
        let count: Int
        do { count = try Stickers.put(sticker, on: board) } catch {
            mlog.error("menu: sticker not read: \(String(describing: error), privacy: .public)")
            return HUD.tip("That picture could not be read")
        }
        Post.key(KeyCode.v, .cmd)
        Task {
            try? await Task.sleep(for: restoreAfter)
            let restored = saved.restore(to: board, ifUnchangedSince: count)
            mlog.notice("menu: sticker pasted, pasteboard \(restored ? "restored" : "left, copied since", privacy: .public)")
        }
    }

    /// A GIPHY pick (story 164) once its download (started at the pick) lands in Pilot's cache: pasted as that file, as
    /// a GIF of the folder is, so chats get it animated.
    static func paste(_ gif: WebGIF, file: Task<URL, any Error>, on board: NSPasteboard = .general) {
        Task {
            do { paste(.image(try await file.value.path), on: board) } catch {
                mlog.error("menu: GIPHY GIF \(gif.id, privacy: .public) not downloaded: \(Giphy.describe(error), privacy: .public)")
                HUD.tip("That GIF did not download")
            }
        }
    }
}
