import Cocoa
import WebKit

// Where the sprites live, reading the sprite sheets and evolution data, and the pw:// scheme.
// (Pokémon Roam, github.com/Maham-Anwaar/pokemon-roam, has its own copy and can use these sprites.)

// MARK: - Paths

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let baseDir = home.appendingPathComponent("Documents/Pokemon Widget")
let spritesDir = baseDir.appendingPathComponent("sprites")

// MARK: - Walk-sheet metadata

/// Extra animations the walkers use when you play with them (see fetch_sprites.sh).
let extraAnims = ["Idle", "Hop", "Attack", "Hurt", "Charge", "Rotate", "Sleep", "Eat", "Wake", "Faint"]

/// Every <Anim> in an AnimData.xml: name -> ["fw", "fh", "durs", "hit"?, "src"], with CopyOf resolved
/// ("src" is the animation whose sheet holds the frames).
let animTagRes: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues:
    ["Name", "CopyOf", "FrameWidth", "FrameHeight", "Duration", "HitFrame"].map {
        ($0, try! NSRegularExpression(pattern: "<\($0)>([^<]*)</\($0)>"))
    })

func parseAnims(_ xml: String) -> [String: [String: Any]] {
    func values(_ s: String, _ tag: String) -> [String] {
        let re = animTagRes[tag]!
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
    var own: [String: [String: Any]] = [:], copies: [String: String] = [:]
    for block in xml.components(separatedBy: "<Anim>").dropFirst() {
        guard let name = values(block, "Name").first else { continue }
        if let src = values(block, "CopyOf").first { copies[name] = src; continue }
        guard let fw = values(block, "FrameWidth").first.flatMap({ Int($0) }),
              let fh = values(block, "FrameHeight").first.flatMap({ Int($0) }) else { continue }
        let durs = values(block, "Duration").compactMap { Int($0) }
        guard !durs.isEmpty else { continue }
        var a: [String: Any] = ["fw": fw, "fh": fh, "durs": durs, "src": name]
        if let hit = values(block, "HitFrame").first.flatMap({ Int($0) }) { a["hit"] = hit }
        own[name] = a
    }
    var out = own
    for (name, src) in copies { if let a = own[src] { out[name] = a } }
    return out
}

func loadWalkData(_ walkDir: URL, animDir: URL) -> [String: Any] {
    var out: [String: Any] = [:]

    for dex in 1...386 {
        let xmlURL = walkDir.appendingPathComponent("\(dex).xml")
        let pngURL = walkDir.appendingPathComponent("\(dex).png")
        guard let xml = try? String(contentsOf: xmlURL, encoding: .utf8) else { continue }
        let parsed = parseAnims(xml)
        guard let walkAnim = parsed["Walk"], let fw = walkAnim["fw"] as? Int, let fh = walkAnim["fh"] as? Int,
              let durs = walkAnim["durs"] as? [Int],
              let src = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }

        let w = img.width, h = img.height
        guard h >= fh * 8 else { continue }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { continue }

        // Content bounds (top/bottom) within one direction row, across all its frames.
        func bounds(row: Int) -> (top: Int, bottom: Int)? {
            var top = Int.max, bottom = -1
            for y in 0..<fh {
                let py = row * fh + y
                var hit = false
                for x in 0..<min(w, fw * durs.count) where buf[(py * w + x) * 4 + 3] > 0 { hit = true; break }
                if hit { top = min(top, y); bottom = max(bottom, y) }
            }
            return bottom >= 0 ? (top, bottom) : nil
        }
        guard let side = bounds(row: 2), let down = bounds(row: 0) else { continue }
        // Extra sheets share the walk sheet's anchor (the frame centre), so they need no pixel scan,
        // just a check that the sheet is there: eight direction rows, or one (Sleep and Eat face the viewer).
        var anims: [String: Any] = [:]
        for name in extraAnims {
            guard let a = parsed[name], let afh = a["fh"] as? Int, let srcName = a["src"] as? String else { continue }
            let url = animDir.appendingPathComponent("\(srcName)/\(dex).png")
            guard let isrc = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(isrc, 0, nil) as? [CFString: Any],
                  let ph = props[kCGImagePropertyPixelHeight] as? Int, ph >= afh else { continue }
            var info = a
            info["rows"] = ph >= afh * 8 ? 8 : 1
            anims[name] = info
        }
        out[String(dex)] = ["fw": fw, "fh": fh, "durs": durs,
                            "padSide": fh - 1 - side.bottom, "padDown": fh - 1 - down.bottom,
                            "h": side.bottom - side.top + 1, "anims": anims]
    }
    return out
}

/// dex -> the dex numbers it can evolve into (written by fetch_sprites.sh).
func loadEvolutions() -> [String: [Int]] {
    guard let data = try? Data(contentsOf: spritesDir.appendingPathComponent("evolutions.json")),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: [Int]] else { return [:] }
    return d
}

// MARK: - Names

let pokemonNames: [String: String] = {
    guard let data = try? Data(contentsOf: spritesDir.appendingPathComponent("names.json")),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
    return d
}()

func displayName(_ dex: Int) -> String {
    let raw = pokemonNames[String(dex)] ?? "#\(dex)"
    let fixes = ["nidoran-f": "Nidoran♀", "nidoran-m": "Nidoran♂", "mr-mime": "Mr. Mime", "farfetchd": "Farfetch’d",
                 "ho-oh": "Ho-Oh"]
    return fixes[raw] ?? raw.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
}

// MARK: - pw:// scheme: pw://app/<file> from the app bundle, pw://sprites/<file> from the sprites folder

final class SchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let rel = String(url.path.dropFirst())
        let root: URL? = url.host == "app" ? Bundle.main.resourceURL : (url.host == "sprites" ? spritesDir : nil)
        guard let root, !rel.contains(".."), let data = try? Data(contentsOf: root.appendingPathComponent(rel)) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "html": mime = "text/html"
        case "gif": mime = "image/gif"
        case "png": mime = "image/png"
        default: mime = "application/octet-stream"
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": String(data.count),
                                                  "Cache-Control": "max-age=86400"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

