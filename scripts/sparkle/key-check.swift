// Checks the Sparkle EdDSA private key on standard input against an expected public key, in memory.
// Usage: printf '%s\n' "$SPARKLE_ED_KEY" | swift scripts/sparkle/key-check.swift <expected SUPublicEDKey>
// Prints only a fixed status line and never the input: Sparkle 2.10.0's own tools echo a key that fails to
// decode, so a malformed key must be stopped here, before it reaches them.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("key-check: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2, let expected = Data(base64Encoded: CommandLine.arguments[1]), expected.count == 32 else {
    fail("usage: key-check.swift <expected base64 public key>")
}
guard let line = readLine(strippingNewline: true) else { fail("no key on standard input") }
guard let secret = Data(base64Encoded: line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    fail("the key is not base64")
}
// Sparkle's decoder (common_cli/Secret.swift) accepts a 32-byte seed or the older 96-byte private+public form;
// its error text claims 64/96, which is wrong.
let derived: Data
switch secret.count {
case 32:
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) else { fail("the seed is not a valid Ed25519 seed") }
    derived = key.publicKey.rawRepresentation
case 96:
    derived = secret.suffix(32)
default:
    fail("the key decodes to \(secret.count) bytes; Sparkle accepts 32 or 96")
}
guard derived == expected else { fail("the key does not match the expected public key") }
print("key-check: ok (\(secret.count == 32 ? "seed" : "legacy") form, matches the public key)")
