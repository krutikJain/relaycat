import Foundation

// Minimal raw Snappy decoder for the IndexedDB blobs where claude.ai caches the signed-in account.
// Output is capped at the declared size, so a malformed blob can't grow memory.
enum Snappy {
    static func varint(_ d: [UInt8], _ p: inout Int) -> Int? {
        var v = 0, s = 0
        while p < d.count {
            let x = Int(d[p]); p += 1
            v |= (x & 127) << s
            if x < 128 { return v }
            s += 7
            if s > 35 { return nil }
        }
        return nil
    }

    static func decompress(_ d: [UInt8]) -> [UInt8]? {
        var p = 0
        guard let n = varint(d, &p), n < 300_000_000 else { return nil }
        var o = [UInt8]()
        o.reserveCapacity(n)
        while p < d.count {
            let tag = Int(d[p]); p += 1
            if tag & 3 == 0 {
                var l = tag >> 2
                if l < 60 { l += 1 } else {
                    let k = l - 59
                    guard p + k <= d.count else { return nil }
                    var v = 0
                    for i in 0..<k { v |= Int(d[p + i]) << (8 * i) }
                    l = v + 1; p += k
                }
                guard p + l <= d.count, o.count + l <= n else { return nil }
                o.append(contentsOf: d[p..<(p + l)]); p += l
            } else {
                var l = 0, off = 0
                switch tag & 3 {
                case 1:
                    guard p < d.count else { return nil }
                    l = 4 + ((tag >> 2) & 7); off = ((tag & 224) << 3) | Int(d[p]); p += 1
                case 2:
                    guard p + 2 <= d.count else { return nil }
                    l = 1 + (tag >> 2); off = Int(d[p]) | Int(d[p + 1]) << 8; p += 2
                default:
                    guard p + 4 <= d.count else { return nil }
                    l = 1 + (tag >> 2)
                    off = Int(d[p]) | Int(d[p + 1]) << 8 | Int(d[p + 2]) << 16 | Int(d[p + 3]) << 24; p += 4
                }
                guard off > 0, off <= o.count, o.count + l <= n else { return nil }
                let start = o.count - off
                for i in 0..<l { o.append(o[start + i]) }
            }
        }
        return o.count == n ? o : nil
    }
}

enum Bytes {
    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int = 0, to: Int? = nil) -> Int? {
        let end = min(to ?? hay.count, hay.count)
        guard from >= 0, from < end, needle.count > 0, needle.count <= end - from else { return nil }
        return hay.withUnsafeBufferPointer { h -> Int? in
            needle.withUnsafeBufferPointer { n -> Int? in
                guard let base = h.baseAddress, let nb = n.baseAddress,
                      let r = memmem(base + from, end - from, nb, n.count) else { return nil }
                return UnsafeRawPointer(r) - UnsafeRawPointer(base)
            }
        }
    }

    static func v8String(_ d: [UInt8], _ q: inout Int) -> String? {
        guard q < d.count else { return nil }
        let tag = d[q]; q += 1
        guard let len = Snappy.varint(d, &q), len >= 0, q + len <= d.count, len < 4096 else { return nil }
        defer { q += len }
        let slice = Array(d[q..<(q + len)])
        switch tag {
        case 0x22: return String(bytes: slice, encoding: .isoLatin1)
        case 0x53: return String(bytes: slice, encoding: .utf8)
        case 0x63: return String(bytes: slice, encoding: .utf16LittleEndian)
        default: return nil
        }
    }
}
