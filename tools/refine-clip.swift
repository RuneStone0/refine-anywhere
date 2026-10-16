// refine-clip: native helper for refine-selection. Fast replacements for osascript calls, plus Slack rich-text support.
//
// Slack rich text: when you copy formatted text in Slack, the clipboard holds a Chromium "web custom data" blob
// (org.chromium.web-custom-data) with a `slack/texty` entry: {"ops":[{"insert":"text","attributes":{...}}, ...]}.
//
//   read-texty                  print the ops JSON. Exit 1: no slack/texty. Exit 2: nothing worth refining (no formatting)
//   text ORIG.json              print the ops' text joined together (what the model sees)
//   apply-diff ORIG.json TXT    refined plain text -> new ops JSON. The refined text is diffed word by word against the
//                               original and each change is applied only inside the single editable run it belongs to
//   verify ORIG.json NEW.json   exit 0 only if NEW has the same runs, attributes, protected runs and line breaks
//   same A.json B.json          exit 0 if both hold identical ops
//   plain NEW.json              print the ops' text joined together (plain-text fallback)
//   write-texty NEW.json ORIG.json   patch the clipboard IN PLACE with the refined text, keeping every other format
//
// Input/UI helpers (each starts in milliseconds, unlike osascript):
//   key a|c|v                   post Cmd+A / Cmd+C / Cmd+V   (needs the Accessibility permission)
//   changecount                 the clipboard's change counter
//   typed-since EPOCH           exit 0 if the user pressed a key or clicked since EPOCH (unix seconds)
//   copy                        post Cmd+C, wait for the clipboard to change, print the copied plain text (exit 1: nothing)
//   modifiers-held              exit 0 while Cmd/Shift/Ctrl/Option are held down
//   front                       print the frontmost app's bundle id
//   trusted                     print true/false: may we post key events?
//   read-html / write-html HTML.txt PLAIN.txt   HTML on the clipboard (other rich-text apps)
//   selftest                    decode + re-encode the clipboard blob and compare bytes
//
// Build: swiftc -O -o refine-clip refine-clip.swift
import Cocoa

let customType = NSPasteboard.PasteboardType("org.chromium.web-custom-data")
let textyKey = "slack/texty"
let plainKey = "public.utf8-plain-text"
let pb = NSPasteboard.general

func fail(_ code: Int32, _ msg: String = "") -> Never {
    if !msg.isEmpty { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!) }
    exit(code)
}

// MARK: Chromium pickle: u32 payload size, u32 entry count, then (string16, string16) pairs.
// A string16 is a u32 length in UTF-16 code units, the units, and padding to a 4-byte boundary.

func parsePickle(_ d: Data) -> [(String, String)]? {
    var pos = 4
    func u32() -> Int? {
        guard pos + 4 <= d.count else { return nil }
        let v = d.subdata(in: pos..<pos + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        pos += 4
        return Int(UInt32(littleEndian: v))
    }
    func str16() -> String? {
        guard let n = u32(), pos + n * 2 <= d.count else { return nil }
        let s = String(data: d.subdata(in: pos..<pos + n * 2), encoding: .utf16LittleEndian)
        pos = (pos + n * 2 + 3) & ~3
        return s
    }
    guard d.count >= 8, let count = u32() else { return nil }
    var out: [(String, String)] = []
    for _ in 0..<count {
        guard let t = str16(), let v = str16() else { return nil }
        out.append((t, v))
    }
    return out
}

func buildPickle(_ entries: [(String, String)]) -> Data {
    var payload = Data()
    func put32(_ v: Int) { var x = UInt32(v).littleEndian; payload.append(Data(bytes: &x, count: 4)) }
    func putStr16(_ s: String) {
        let units = s.data(using: .utf16LittleEndian)!
        put32(units.count / 2)
        payload.append(units)
        while payload.count % 4 != 0 { payload.append(0) }
    }
    put32(entries.count)
    for (t, v) in entries { putStr16(t); putStr16(v) }
    var header = UInt32(payload.count).littleEndian
    return Data(bytes: &header, count: 4) + payload
}

// MARK: ops helpers

typealias Op = [String: Any]

func readOps(_ json: String) -> [Op]? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ops = obj["ops"] as? [Op] else { return nil }
    return ops
}
func readOpsFile(_ path: String) -> [Op]? {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return readOps(s)
}
func opsJSON(_ ops: [Op]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: ["ops": ops], options: [.withoutEscapingSlashes, .sortedKeys]), encoding: .utf8)!
}
func newlineCount(_ s: String) -> Int { s.filter { $0 == "\n" }.count }

// Runs that must never be reworded: Slack mentions, smart links, emoji... (any "slack*" attribute) store their
// own copy of the text inside the attributes, and a link whose visible text is the URL itself.
func isProtected(_ op: Op) -> Bool {
    guard let attrs = op["attributes"] as? [String: Any] else { return false }
    if attrs.keys.contains(where: { $0.hasPrefix("slack") }) { return true }
    if let link = attrs["link"] as? String, let text = op["insert"] as? String, link == text { return true }
    return false
}
// A run the refinement may touch: plain text with at least one non-whitespace character, not protected.
func isEditable(_ op: Op) -> Bool {
    guard let s = op["insert"] as? String, !isProtected(op) else { return false }
    return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
func urls(in ops: [Op]) -> Set<String> {
    let text = ops.compactMap { $0["insert"] as? String }.joined(separator: "\n")
    guard let re = try? NSRegularExpression(pattern: "https?://[^\\s\"<>]+") else { return [] }
    let ns = text as NSString
    return Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
}
// Text of a run as the model sees it; non-text embeds (emoji images etc.) count as one placeholder character.
func runText(_ op: Op) -> String { (op["insert"] as? String) ?? "\u{FFFC}" }

func clipboardTexty() -> (entries: [(String, String)], ops: [Op])? {
    guard let data = pb.data(forType: customType), let entries = parsePickle(data),
          let t = entries.first(where: { $0.0 == textyKey }), let ops = readOps(t.1) else { return nil }
    return (entries, ops)
}

// MARK: word-level diff, projected onto runs

struct Tok { let s: String; let range: NSRange }

func tokenize(_ text: String) -> [Tok] {
    let re = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_'\u{2019}]+|\\s+|[^\\p{L}\\p{N}_'\u{2019}\\s]")
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Tok(s: ns.substring(with: $0.range), range: $0.range) }
}

struct Hunk { var a0: Int, a1: Int, b0: Int, b1: Int }   // token index ranges in original / refined

func diffHunks(_ a: [Tok], _ b: [Tok]) -> [Hunk]? {
    let n = a.count, m = b.count
    guard n * m <= 16_000_000 else { return nil }
    // dp[i][j] = length of the longest common subsequence of a[i...] and b[j...]
    var dp = [[UInt16]](repeating: [UInt16](repeating: 0, count: m + 1), count: n + 1)
    if n > 0 && m > 0 {
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i].s == b[j].s ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
    }
    var hunks: [Hunk] = []
    var i = 0, j = 0
    var pend: (Int, Int)? = nil
    while i < n || j < m {
        if i < n && j < m && a[i].s == b[j].s {
            if let p = pend { hunks.append(Hunk(a0: p.0, a1: i, b0: p.1, b1: j)); pend = nil }
            i += 1; j += 1
        } else {
            if pend == nil { pend = (i, j) }
            if j < m && (i == n || dp[i][j + 1] >= dp[i + 1][j]) { j += 1 } else { i += 1 }
        }
    }
    if let p = pend { hunks.append(Hunk(a0: p.0, a1: n, b0: p.1, b1: m)) }
    return hunks
}

// One logical edit often shows up as several hunks separated by a single matching space ("ou side" -> "outside.").
// Applying only some of them would garble the text, so hunks separated by one whitespace token become one.
func mergeNearby(_ hunks: [Hunk], _ a: [Tok]) -> [Hunk] {
    var out: [Hunk] = []
    for h in hunks {
        if var last = out.last, h.a0 - last.a1 <= 1,
           (h.a0 - last.a1 == 0 || a[last.a1].s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            last.a1 = h.a1; last.b1 = h.b1
            out[out.count - 1] = last
        } else { out.append(h) }
    }
    return out
}

func applyDiff(orig: [Op], refined: String) -> [Op]? {
    let texts = orig.map(runText)
    var starts: [Int] = [], ends: [Int] = [], pos = 0
    for t in texts { starts.append(pos); pos += (t as NSString).length; ends.append(pos) }
    let original = texts.joined()
    let ta = tokenize(original), tb = tokenize(refined)
    guard let raw = diffHunks(ta, tb) else { return nil }
    let hunks = mergeNearby(raw, ta)
    let refinedNS = refined as NSString

    var edits = [[(Int, Int, String)]](repeating: [], count: orig.count)   // per run: (local start, local end, new text)
    for h in hunks {
        let a: Int, b: Int
        if h.a0 < h.a1 {
            a = ta[h.a0].range.location
            b = ta[h.a1 - 1].range.location + ta[h.a1 - 1].range.length
        } else {
            a = h.a0 < ta.count ? ta[h.a0].range.location : pos
            b = a
        }
        let newText: String
        if h.b0 < h.b1 {
            let s = tb[h.b0].range.location
            let e = tb[h.b1 - 1].range.location + tb[h.b1 - 1].range.length
            newText = refinedNS.substring(with: NSRange(location: s, length: e - s))
        } else { newText = "" }

        var run: Int? = nil
        if a < b {
            run = (0..<orig.count).first { starts[$0] <= a && b <= ends[$0] }
        } else {   // pure insertion: attach to the run that contains the preceding character
            if let r = (0..<orig.count).first(where: { starts[$0] < a && a <= ends[$0] }) { run = r }
            else if a == 0, !orig.isEmpty { run = 0 }
            if let r = run, !isEditable(orig[r]), let next = (0..<orig.count).first(where: { starts[$0] == a }), isEditable(orig[next]) { run = next }
        }
        guard let r = run, isEditable(orig[r]) else { continue }
        edits[r].append((a - starts[r], b - starts[r], newText))
    }

    var result = orig
    for (r, list) in edits.enumerated() where !list.isEmpty {
        var s = (orig[r]["insert"] as! String) as NSString
        for (ls, le, t) in list.sorted(by: { $0.0 > $1.0 }) {
            s = s.replacingCharacters(in: NSRange(location: ls, length: le - ls), with: t) as NSString
        }
        result[r]["insert"] = s as String
    }
    return result
}

// MARK: commands

let args = CommandLine.arguments
guard args.count >= 2 else { fail(64, "usage: refine-clip <command>   (see the header of refine-clip.swift)") }

switch args[1] {
case "read-texty":
    guard let (_, ops) = clipboardTexty() else { fail(1) }
    let hasAttributes = ops.contains { ($0["attributes"] as? [String: Any])?.isEmpty == false }
    let hasEmbeds = ops.contains { !($0["insert"] is String) }
    guard hasAttributes || hasEmbeds else { fail(2) }
    FileHandle.standardOutput.write(opsJSON(ops).data(using: .utf8)!)

case "text":
    guard args.count >= 3, let ops = readOpsFile(args[2]) else { fail(1) }
    print(ops.map(runText).joined(), terminator: "")

case "apply-diff":
    guard args.count >= 4, let orig = readOpsFile(args[2]),
          let refined = try? String(contentsOfFile: args[3], encoding: .utf8),
          let result = applyDiff(orig: orig, refined: refined) else { fail(1) }
    FileHandle.standardOutput.write(opsJSON(result).data(using: .utf8)!)

case "verify":
    guard args.count >= 4, let a = readOpsFile(args[2]), let b = readOpsFile(args[3]), a.count == b.count else { fail(1) }
    for (x, y) in zip(a, b) {
        let ax = (x["attributes"] as? NSDictionary) ?? [:], ay = (y["attributes"] as? NSDictionary) ?? [:]
        guard ax.isEqual(ay) else { fail(1, "attributes differ") }
        if let sx = x["insert"] as? String {
            guard let sy = y["insert"] as? String else { fail(1, "run type differs") }
            if !isEditable(x) { guard newlineCount(sx) == newlineCount(sy) else { fail(1, "line breaks changed in a locked run") } }
            if isProtected(x) { guard sx == sy else { fail(1, "protected run changed") } }
            if sx.trimmingCharacters(in: .newlines).isEmpty { guard sx == sy else { fail(1, "newline run changed") } }
        } else {
            guard (x["insert"] as? NSObject)?.isEqual(y["insert"]) == true else { fail(1, "embed differs") }
        }
    }
    guard urls(in: a).isSubset(of: urls(in: b)) else { fail(1, "a URL changed") }

case "same":
    guard args.count >= 4, let a = readOpsFile(args[2]), let b = readOpsFile(args[3]) else { fail(1) }
    guard NSArray(array: a).isEqual(to: b) else { fail(1) }

case "plain":
    guard args.count >= 3, let ops = readOpsFile(args[2]) else { fail(1) }
    print(ops.compactMap { $0["insert"] as? String }.joined(), terminator: "")

case "write-texty":
    guard args.count >= 4, let new = readOpsFile(args[2]), let orig = readOpsFile(args[3]), new.count == orig.count,
          let (entries, _) = clipboardTexty(),
          let plain = entries.first(where: { $0.0 == plainKey })?.1 ?? pb.string(forType: .string) else { fail(1, "cannot read clipboard") }

    // Map the refined runs back onto the ORIGINAL plain text so list bullets, URLs etc. stay as Slack wrote them.
    // Runs whose plain-text form differs (smart links print their URL, embeds print nothing) are simply skipped.
    var result = plain as NSString
    var cursor = 0
    for (o, n) in zip(orig, new) {
        guard let a = o["insert"] as? String, let b = n["insert"] as? String, !a.isEmpty else { continue }
        let r = result.range(of: a, options: [], range: NSRange(location: cursor, length: result.length - cursor))
        guard r.location != NSNotFound else { continue }
        if a != b { result = result.replacingCharacters(in: r, with: b) as NSString }
        cursor = r.location + (b as NSString).length
    }
    let newPlain = result as String
    let newJSON = opsJSON(new)
    let patched = entries.map { e -> (String, String) in
        e.0 == textyKey ? (e.0, newJSON) : e.0 == plainKey ? (e.0, newPlain) : e
    }

    // macOS silently ignores setData on a pasteboard another app owns, so take everything off it, clear it,
    // and write every format back (the untouched ones with their original bytes).
    let types = pb.types ?? []
    var saved: [NSPasteboard.PasteboardType: Data] = [:]
    for t in types { if let d = pb.data(forType: t) { saved[t] = d } }
    pb.clearContents()
    pb.declareTypes(types, owner: nil)
    var ok = true
    for t in types {
        if t == customType { ok = pb.setData(buildPickle(patched), forType: t) && ok }
        else if t == .string || t.rawValue == "NSStringPboardType" { ok = pb.setString(newPlain, forType: t) && ok }   // legacy alias of the same text
        else if let d = saved[t] { ok = pb.setData(d, forType: t) && ok }
    }
    guard ok, pb.string(forType: .string) == newPlain,
          let back = clipboardTexty(), NSArray(array: back.ops).isEqual(to: new) else { fail(1, "clipboard write did not take effect") }

case "key":
    let codes: [String: CGKeyCode] = ["a": 0, "c": 8, "v": 9]
    guard args.count >= 3, let code = codes[args[2]] else { fail(64, "key a|c|v") }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail(1) }
        e.flags = .maskCommand
        e.post(tap: .cghidEventTap)
        usleep(15_000)
    }
    usleep(150_000)   // stay alive until the window server has delivered the events; exiting at once can drop them

case "copy":   // post Cmd+C, wait (max ~1s) for the clipboard to change, print the plain text. Exit 1 if nothing was copied.
    let before = pb.changeCount
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: down) else { fail(1) }
        e.flags = .maskCommand
        e.post(tap: .cghidEventTap)
    }
    let deadline = Date().addingTimeInterval(1.0)
    while pb.changeCount == before && Date() < deadline { usleep(10_000) }
    guard pb.changeCount != before else { fail(1, "clipboard did not change") }
    usleep(40_000)   // let the app finish writing all formats
    print(pb.string(forType: .string) ?? "", terminator: "")

case "changecount":
    print(pb.changeCount)

case "typed-since":   // EPOCH (unix seconds): exit 0 if the user pressed a key or clicked after that moment
    guard args.count >= 3, let epoch = Double(args[2]) else { fail(64, "typed-since EPOCH") }
    let now = Date().timeIntervalSince1970
    func last(_ t: CGEventType) -> Double { now - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t) }
    exit(max(last(.keyDown), last(.leftMouseDown), last(.rightMouseDown)) > epoch ? 0 : 1)

case "modifiers-held":
    let f = CGEventSource.flagsState(.combinedSessionState)
    exit(f.contains(.maskCommand) || f.contains(.maskShift) || f.contains(.maskControl) || f.contains(.maskAlternate) ? 0 : 1)

case "front":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")

case "trusted":
    print(AXIsProcessTrusted())

case "read-html":
    guard let s = pb.string(forType: .html) else { fail(1) }
    print(s, terminator: "")

case "write-html":
    guard args.count >= 4, let html = try? String(contentsOfFile: args[2], encoding: .utf8),
          let plain = try? String(contentsOfFile: args[3], encoding: .utf8) else { fail(1) }
    pb.clearContents()
    pb.setString(html, forType: .html)
    pb.setString(plain, forType: .string)

case "selftest":
    guard let data = pb.data(forType: customType), let entries = parsePickle(data) else { fail(1, "no custom data") }
    print(buildPickle(entries) == data ? "roundtrip-identical" : "roundtrip-DIFFERENT (\(data.count) vs \(buildPickle(entries).count) bytes)")

default:
    fail(64, "unknown command \(args[1])")
}
