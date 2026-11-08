// SPDX-License-Identifier: GPL-3.0-only
// QRC/KRC format and nonstandard DES tables adapted from LDDC.
// Copyright (C) 2024-2025 沉默の金 <cmzj@cmzj.org>
// https://github.com/chenmozhijin/LDDC/tree/main/LDDC/core/decryptor
import Foundation

enum LyricsCipher {
    static func inflate(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count < 8_388_608 else { throw PureToneError.message("歌词数据无效") }
        var output = [UInt8](repeating: 0, count: 16_777_216)
        var count = uLongf(output.count)
        let status = data.withUnsafeBytes { input in
            uncompress(&output, &count, input.bindMemory(to: UInt8.self).baseAddress, uLong(data.count))
        }
        guard status == Z_OK, let text = String(bytes: output.prefix(Int(count)), encoding: .utf8) else {
            throw PureToneError.message("歌词解压失败")
        }
        return text
    }
    static func krc(_ data: Data) throws -> String {
        guard data.count > 4, data.prefix(4) == Data("krc1".utf8) else {
            if let text = String(data: data, encoding: .utf8) { return text }
            throw PureToneError.message("无效的 KRC 文件")
        }
        let key: [UInt8] = [64,71,97,119,94,50,116,71,81,54,49,45,206,210,110,105]
        return try inflate(Data(data.dropFirst(4).enumerated().map { $0.element ^ key[$0.offset % key.count] }))
    }
    static func qrc(_ hex: String) throws -> String {
        if hex.contains("[") || hex.contains("<") { return hex }
        let text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count % 16 == 0, text.count < 16_777_216 else { throw PureToneError.message("QRC 密文长度无效") }
        var encrypted: [UInt8] = []; encrypted.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw PureToneError.message("QRC 密文无效") }
            encrypted.append(byte); index = next
        }
        let key = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)
        let schedules = [(16, true), (8, false), (0, true)].map { schedule(Array(key[$0.0..<$0.0+8]), decrypt: $0.1) }
        var output: [UInt8] = []
        for offset in stride(from: 0, to: encrypted.count, by: 8) {
            var block = Array(encrypted[offset..<offset+8])
            for keys in schedules { block = crypt(block, keys: keys) }
            output.append(contentsOf: block)
        }
        return try inflate(Data(output))
    }
    private static let sbox: [[UInt8]] = [[14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],[15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,15,12,0,1,10,6,9,11,5,0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],[10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],[7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,10,13,8,9,4,5,11,12,7,2,14],[2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],[12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],[4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],[13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11]]
    private static let ip = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7]
    private static let fp = [40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25]
    private static let pc1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4]
    private static let pc2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32]
    private static let expansion = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1]
    private static let permutation = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25]
    private static func permute(_ input: UInt64, bits: Int, table: [Int]) -> UInt64 {
        table.reduce(UInt64(0)) { ($0 << 1) | ((input >> (bits - $1)) & 1) }
    }
    private static func swappedWords(_ bytes: [UInt8]) -> [UInt8] { [bytes[3],bytes[2],bytes[1],bytes[0],bytes[7],bytes[6],bytes[5],bytes[4]] }
    private static func value(_ bytes: [UInt8]) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
    private static func schedule(_ bytes: [UInt8], decrypt: Bool) -> [UInt64] {
        let key = permute(value(swappedWords(bytes)), bits: 64, table: pc1)
        var c = key >> 28, d = key & 0x0fffffff; var result: [UInt64] = []
        for shift in [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1] {
            c = ((c << shift) | (c >> (28-shift))) & 0x0fffffff
            d = ((d << shift) | (d >> (28-shift))) & 0x0fffffff
            // QRC uses the upstream nonstandard D-half indexing (+1), not stock DES PC2.
            var round: UInt64 = 0
            for position in pc2 {
                let bit: UInt64
                if position <= 28 { bit = (c >> (28-position)) & 1 }
                else { let index = position-28; bit = index < 28 ? (d >> (27-index)) & 1 : 0 }
                round = (round << 1) | bit
            }
            result.append(round)
        }
        return decrypt ? Array(result.reversed()) : result
    }
    private static func crypt(_ bytes: [UInt8], keys: [UInt64]) -> [UInt8] {
        let initial = permute(value(swappedWords(bytes)), bits: 64, table: ip)
        var left = UInt32(initial >> 32), right = UInt32(initial & 0xffffffff)
        for key in keys {
            let expanded = permute(UInt64(right), bits: 32, table: expansion) ^ key
            var substituted: UInt32 = 0
            for i in 0..<8 {
                let six = Int((expanded >> ((7-i)*6)) & 63)
                let address = (six & 32) | ((six & 31) >> 1) | ((six & 1) << 4)
                substituted = (substituted << 4) | UInt32(sbox[i][address])
            }
            let f = UInt32(permute(UInt64(substituted), bits: 32, table: permutation))
            (left, right) = (right, left ^ f)
        }
        let final = permute((UInt64(right) << 32) | UInt64(left), bits: 64, table: fp)
        return swappedWords((0..<8).map { UInt8((final >> ((7-$0)*8)) & 255) })
    }
}
