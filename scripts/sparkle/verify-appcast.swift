// Verifies a signed Dimmer appcast with the public key only, the way Sparkle 2.10.0 will read it.
// Usage: swift scripts/sparkle/verify-appcast.swift <appcast.xml> <SUPublicEDKey> <archives dir> [<URL template>]
// Checks: the feed signature over everything before the trailing signing block (SPUExtractSignedFeed.m);
// every enclosure whose archive is in <archives dir>: byte length and EdDSA signature over the final bytes;
// every item: minimum macOS 14.0, embedded notes with no scripts or remote content, and a download URL that
// is version-specific: the template with {version} replaced, then Dimmer-<version>.dmg. The default template is
// Dimmer's GitHub release download path.
import CryptoKit
import Foundation

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print("\(ok ? "ok  " : "FAIL") \(message)")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
guard args.count == 4 || args.count == 5,
      let keyData = Data(base64Encoded: args[2]), keyData.count == 32,
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("usage: verify-appcast.swift <appcast.xml> <public key> <archives dir> [<url template>]\n".utf8))
    exit(2)
}
let feedURL = URL(fileURLWithPath: args[1])
let archives = URL(fileURLWithPath: args[3], isDirectory: true)
let template = args.count == 5 ? args[4] : "https://github.com/kalkman-code/dimmer/releases/download/v{version}/"

let feed = try Data(contentsOf: feedURL)
let marker = Data("<!-- sparkle-signatures:\n".utf8)
guard let blockStart = feed.range(of: marker, options: .backwards),
      let blockEnd = feed.range(of: Data("-->".utf8), in: blockStart.upperBound..<feed.endIndex) else {
    check(false, "feed carries a sparkle-signatures block")
    exit(1)
}
let content = feed.subdata(in: feed.startIndex..<blockStart.lowerBound)
let block = String(decoding: feed.subdata(in: blockStart.upperBound..<blockEnd.lowerBound), as: UTF8.self)
func field(_ name: String) -> String? {
    block.split(separator: "\n").first { $0.hasPrefix(name) }.map { $0.dropFirst(name.count).trimmingCharacters(in: .whitespaces) }
}
let feedSignature = field("edSignature:").flatMap { Data(base64Encoded: $0) }
check(field("length:").flatMap(Int.init) == content.count, "feed signing block length matches the content (\(content.count) bytes)")
check(feedSignature.map { publicKey.isValidSignature($0, for: content) } == true, "feed signature verifies with the public key")

let document = try XMLDocument(data: content)
let items = try document.nodes(forXPath: "//channel/item").compactMap { $0 as? XMLElement }
check(!items.isEmpty, "feed has \(items.count) item(s)")
var versions: [Int] = []
for item in items {
    func text(_ name: String) -> String? { item.elements(forName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
    let short = text("sparkle:shortVersionString") ?? "?"
    let build = text("sparkle:version") ?? "?"
    versions.append(Int(build) ?? -1)
    check(text("sparkle:minimumSystemVersion") == "14.0", "\(short) (\(build)): minimum macOS is 14.0")
    let notes = item.elements(forName: "description").first?.stringValue ?? ""
    let lower = notes.lowercased()
    check(!notes.isEmpty && !lower.contains("<script") && !lower.contains("src=\"http") && !lower.contains("src='http"),
          "\(short) (\(build)): release notes are embedded, with no scripts or remote content")
    guard let enclosure = item.elements(forName: "enclosure").first,
          let url = enclosure.attribute(forName: "url")?.stringValue,
          let length = enclosure.attribute(forName: "length")?.stringValue.flatMap(Int.init),
          let signature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
        check(false, "\(short) (\(build)): enclosure has url, length and edSignature")
        continue
    }
    let expected = template.replacingOccurrences(of: "{version}", with: short) + "Dimmer-\(short).dmg"
    check(url == expected, "\(short) (\(build)): download URL is \(expected)")
    let archive = archives.appendingPathComponent(URL(string: url)?.lastPathComponent ?? "")
    guard let bytes = try? Data(contentsOf: archive) else {
        print("skip \(short) (\(build)): \(archive.lastPathComponent) not in the archives folder, so its bytes were not checked")
        continue
    }
    check(bytes.count == length, "\(short) (\(build)): enclosure length matches \(archive.lastPathComponent) (\(bytes.count) bytes)")
    check(publicKey.isValidSignature(signature, for: bytes), "\(short) (\(build)): archive signature verifies over the final bytes")
}
check(Set(versions).count == versions.count, "no build number appears twice")
print(failures == 0 ? "verify-appcast: all checks passed" : "verify-appcast: \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
