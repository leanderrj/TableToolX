import Foundation

public enum PackedRowCodec {
    public static func encode(_ values: [String]) -> Data {
        var result = Data()
        appendVarint(UInt64(values.count), to: &result)
        for value in values {
            let bytes = Data(value.utf8)
            appendVarint(UInt64(bytes.count), to: &result)
            result.append(bytes)
        }
        return result
    }

    public static func decode(_ data: Data) throws -> [String] {
        var index = data.startIndex
        let count = try readVarint(data, index: &index)
        guard count <= 1_000_000 else { throw PackedRowError.invalidData }
        var values: [String] = []
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            let length = try readVarint(data, index: &index)
            guard length <= UInt64(data.distance(from: index, to: data.endIndex)) else { throw PackedRowError.invalidData }
            let end = data.index(index, offsetBy: Int(length))
            guard let value = String(data: data[index..<end], encoding: .utf8) else { throw PackedRowError.invalidUTF8 }
            values.append(value)
            index = end
        }
        guard index == data.endIndex else { throw PackedRowError.invalidData }
        return values
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }

    private static func readVarint(_ data: Data, index: inout Data.Index) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw PackedRowError.invalidData
    }
}

public enum PackedRowError: Error {
    case invalidData
    case invalidUTF8
}

