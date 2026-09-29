//
//  OSCEncoder.swift
//  Midi Set List
//

import Foundation

/// Pure-function OSC packet encoder. Separate from OSCManager so it can be unit-tested.
enum OSCEncoder {

    /// Encodes an OSC message with an optional float argument.
    /// Format: padded(address) + padded(typeTag) + bigEndian(float?)
    static func encode(address: String, floatArg: Float?) -> Data {
        var data = Data()
        data.append(padded(address))

        let typeTag = floatArg != nil ? ",f" : ","
        data.append(padded(typeTag))

        if let f = floatArg {
            var bits = f.bitPattern.bigEndian
            data.append(Data(bytes: &bits, count: 4))
        }
        return data
    }

    /// Null-terminates and zero-pads a string to the next 4-byte boundary.
    static func padded(_ string: String) -> Data {
        var d = Data(string.utf8)
        d.append(0)                         // null terminator
        while d.count % 4 != 0 { d.append(0) }
        return d
    }
}
