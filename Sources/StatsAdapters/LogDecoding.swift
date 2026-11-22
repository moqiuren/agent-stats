import CZstd
import Foundation

// Host rollout logs are plain JSONL while they are live, but Codex compresses
// older pages to `*.jsonl.zst` and rewrites the catalog path to the compressed
// file. Reading compressed bytes as JSONL produces only phantom parse errors,
// so every log page is classified before parsing: text is parsed as lines,
// zstd is inflated through a streaming decoder, and anything else stays
// unreadable instead of being counted as malformed records.
package enum LogEncoding: String {
  case text
  case zstd
  case unsupported
}

package enum LogDecoding {
  // Zstandard frame magic and the little-endian skippable-frame magic range.
  private static let zstdFrame: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
  // gzip/zip/bzip2/xz signatures are recognised only to refuse them explicitly;
  // nothing else in this pipeline may treat binary payloads as text lines.
  private static let binarySignatures: [[UInt8]] = [
    [0x1F, 0x8B],  // gzip
    [0x50, 0x4B, 0x03, 0x04],  // zip
    [0x42, 0x5A, 0x68],  // bzip2
    [0xFD, 0x37, 0x7A, 0x58, 0x5A],  // xz
  ]

  package static func encoding(of prefix: Data) -> LogEncoding {
    if prefix.isEmpty { return .text }
    let bytes = [UInt8](prefix.prefix(8))
    if bytes.starts(with: zstdFrame) { return .zstd }
    // Skippable frames carry the same stream semantics for a decoder.
    if bytes.count >= 4, bytes[3] == 0x18, bytes[2] == 0x4D, bytes[1] == 0x2A,
      (0x50...0x5F).contains(bytes[0])
    {
      return .zstd
    }
    for signature in binarySignatures where bytes.starts(with: signature) { return .unsupported }
    // A JSONL line starts with a printable or whitespace byte. A NUL inside the
    // first bytes means binary content that only ever produced garbage lines.
    if bytes.contains(0) { return .unsupported }
    return .text
  }

  static func encoding(at file: URL, limit: Int = 8) -> LogEncoding {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return .unsupported }
    defer { try? handle.close() }
    // read(upToCount:) reports nil at end of file; an empty log is plain text.
    let data = (try? handle.read(upToCount: limit)) ?? Data()
    return encoding(of: data)
  }

  // Streams a compressed page through the caller's chunk consumer. Returns the
  // number of decompressed bytes delivered; throws on a corrupt stream so the
  // caller can report one failure instead of counting garbage lines. A byte
  // budget stops early for prefix probes.
  static func inflate(
    file: URL, chunkSize: Int = 262_144, maxBytes: UInt64 = .max,
    into body: (Data) throws -> Void
  ) throws -> UInt64 {
    guard let stream = ZSTD_createDStream() else { throw LogDecodingError.decoderUnavailable }
    defer { ZSTD_freeDStream(stream) }
    var result = ZSTD_initDStream(stream)
    guard ZSTD_isError(result) == 0 else { throw LogDecodingError.corruptStream(errorName(result)) }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var produced: UInt64 = 0
    var output = [UInt8](repeating: 0, count: chunkSize)
    while produced < maxBytes {
      let chunk = try handle.read(upToCount: chunkSize) ?? Data()
      if chunk.isEmpty { break }
      try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
        while input.pos < input.size && produced < maxBytes {
          let written = output.withUnsafeMutableBufferPointer { buffer -> Int in
            var out = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
            result = ZSTD_decompressStream(stream, &out, &input)
            return out.pos
          }
          guard ZSTD_isError(result) == 0 else { throw LogDecodingError.corruptStream(errorName(result)) }
          if written > 0 {
            produced += UInt64(written)
            try body(Data(bytes: output, count: written))
          }
          if written == 0 && input.pos < input.size { throw LogDecodingError.corruptStream("no progress") }
        }
      }
    }
    return produced
  }

  private static func errorName(_ code: Int) -> String {
    guard let name = ZSTD_getErrorName(code) else { return "zstd error \(code)" }
    return String(cString: name)
  }
}

enum LogDecodingError: Error, CustomStringConvertible {
  case decoderUnavailable
  case corruptStream(String)

  var description: String {
    switch self {
    case .decoderUnavailable: return "zstd decoder unavailable"
    case .corruptStream(let reason): return "corrupt zstd stream: " + reason
    }
  }
}
