//
//  ChunkUtils.swift
//  ChunkTimerPeri
//
//  Created by Jay Tucker on 6/30/15.
//  Copyright (c) 2015 Imprivata. All rights reserved.
//

import Foundation

enum ChunkFlag: UInt8, Printable {
    case First  = 1
    case Middle = 0
    case Last   = 2
    case Only   = 3
    
    var description: String {
        switch(self) {
        case .First:  return "F"
        case .Middle: return "M"
        case .Last:   return "L"
        case .Only:   return "O"
        }
    }
}

class Chunker {
    class func makeChunks(bytes: [UInt8], var chunkSize: Int) -> Array< Array<UInt8> > {
        if chunkSize < 1 || chunkSize > 0x1fff {
            chunkSize = 0x1fff
        }
        var chunks = Array<Array<UInt8>>()
        let totalSize = bytes.count
        var begIdx = 0
        while (begIdx < totalSize) {
            let nextBegIdx = begIdx + chunkSize
            let endIdx = min(nextBegIdx, totalSize)
            var flag: ChunkFlag
            if chunks.isEmpty {
                if nextBegIdx < totalSize {
                    flag = ChunkFlag.First
                } else {
                    flag = ChunkFlag.Only
                }
            } else {
                if nextBegIdx < totalSize {
                    flag = ChunkFlag.Middle
                } else {
                    flag = ChunkFlag.Last
                }
            }
            let chunkDataBytes = Array<UInt8>(bytes[begIdx..<endIdx])
            let length = chunkDataBytes.count
            let header: [UInt8]
            var byte0 = (flag.rawValue << 6)
            if length <= 0x1f {
                byte0 += UInt8(length)
                header = [byte0]
            } else {
                byte0 |= 0x20
                byte0 += UInt8(length >> 8)
                let byte1 = UInt8(length & 0xff)
                header = [byte0, byte1]
            }
            chunks.append(header + chunkDataBytes)
            begIdx = nextBegIdx
        }
        return chunks
    }
}

class Dechunker {
    private var buffer: [UInt8]
    private var nChunksAdded: Int
    private var startTime = NSDate()
    
    init() {
        buffer = [UInt8]()
        nChunksAdded = 0
    }
    
    func addChunk(var bytes: [UInt8]) -> (isSuccess: Bool, finalResult: [UInt8]?) {
        log("dechunker attempting to add chunk of \(bytes.count) bytes")
        
        if bytes.isEmpty {
            log("dechunker failed: too few bytes")
            return (false, nil)
        }
        
        let flagRawValue = bytes[0] >> 6
        let flag = ChunkFlag(rawValue: flagRawValue)!
        let length: Int
        let data: [UInt8]
        if bytes[0] & 0x20 == 0 {
            length = Int(bytes[0] & 0x1f)
            data = Array<UInt8>(bytes[1..<bytes.count])
        } else {
            if bytes.count < 2 {
                log("dechunker failed: too few bytes")
                return (false, nil)
            }
            length = (Int((bytes[0] & 0x1f)) << 8) + Int(bytes[1])
            data = Array<UInt8>(bytes[2..<bytes.count])
        }
        
        if length != data.count {
            log("dechunker failed: bad length")
            return (false, nil)
        }
        
        switch flag {
        case .First, .Only:
            startTime = NSDate()
            buffer = data
            nChunksAdded = 1
            log("dechunker created buffer with \(data.count) bytes (\(flag.description))")
        case .Middle, .Last:
            let oldCount = buffer.count
            buffer += data
            nChunksAdded++
            log("dechunker enlarged buffer to \(data.count)+\(oldCount)=\(buffer.count) bytes (\(nChunksAdded) chunks) (\(flag.description))")
        }
        
        switch flag {
        case .Last, .Only:
            let timeInterval = startTime.timeIntervalSinceNow
            log("dechunker complete, \(nChunksAdded) chunk(s), \(buffer.count) bytes, \(-timeInterval) secs")
            return (true, buffer)
        case .First, .Middle:
            return (true, nil)
        }
    }
    
}

func dumpChunks(chunks: Array< Array<UInt8> >) {
    for chunk in chunks {
        let flagRawValue = chunk[0] >> 6
        let flag = ChunkFlag(rawValue: flagRawValue)!
        let length: Int
        if chunk[0] & 0x20 == 0 {
            length = Int(chunk[0] & 0x1f)
        } else {
            length = (Int((chunk[0] & 0x1f)) << 8) + Int(chunk[1])
        }
        print("(\(flag.description),\(length)): [")
        for i in 0..<chunk.count {
            let s: String
            if i == 0 || i == 1 && length > 0x1f {
                s = String(format: "0x%02x", chunk[i])
            } else {
                s = String(format: "%d", chunk[i])
            }
            if i != 0 {
                print(", ")
            }
            print(s)
        }
        log("]")
    }
}
