// pilot-text: the clipboard's image text read in a process of its own (story 142). Pilot hands it one image on stdin; it
// prints what VisionText reads and exits, so Vision's models and buffers go with it. Read in Pilot they stayed after the
// first image copy, about 60 MB of idle footprint (2026-10-11).
//   pilot-text text             the image's lines
//   pilot-text boxes <word>…    where the words are written, a box a line: x y width height, 0 to 1, origin top left
//   pilot-text codes            the QR codes' payloads, a JSON string a line (the clipboard preview's Open link, Q398)
//   pilot-text lines            every line and code with its box, a JSON line each (ReadLines; the capture's OCR)
//   pilot-text subject          the picture's subjects as PNG, the background transparent (Capture subject, P72); exits 1 with none
//   pilot-text batch            the text index's images (Homy-style Files): a JSON string path a line on stdin, a JSON
//                               line out per image as it is read, {"path", "text"}, at background priority
import Clipboard
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "text":
    print(await VisionText().text(in: FileHandle.standardInput.readDataToEndOfFile()), terminator: "")
case "boxes":
    let image = FileHandle.standardInput.readDataToEndOfFile()
    print(BoxLines.text(await VisionText().boxes(of: Array(arguments.dropFirst()), in: image)), terminator: "")
case "codes":
    let codes = await VisionText().codes(in: FileHandle.standardInput.readDataToEndOfFile())
    print(codes.compactMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }.map { $0 + "\n" }.joined(), terminator: "")
case "lines":
    print(ReadLines.json(await VisionText().lines(in: FileHandle.standardInput.readDataToEndOfFile())), terminator: "")
case "subject":
    guard let png = await VisionSubject().subject(in: FileHandle.standardInput.readDataToEndOfFile()) else {
        FileHandle.standardError.write(Data("no subject\n".utf8))
        exit(1)
    }
    FileHandle.standardOutput.write(png)
case "batch":
    // Efficiency cores and throttled disk reads: the Mac never notices the first pass.
    setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)
    let vision = VisionText()
    while let line = readLine(), getppid() != 1 {
        guard let path = try? JSONDecoder().decode(String.self, from: Data(line.utf8)) else { continue }
        let text = if let image = try? Data(contentsOf: URL(filePath: path)) { await vision.text(in: image) } else { "" }
        let out = try JSONSerialization.data(withJSONObject: ["path": path, "text": text])
        FileHandle.standardOutput.write(out + Data("\n".utf8))
    }
default:
    FileHandle.standardError.write(Data("usage: pilot-text text | boxes <word>… | codes | lines | subject | batch\n".utf8))
    exit(2)
}
