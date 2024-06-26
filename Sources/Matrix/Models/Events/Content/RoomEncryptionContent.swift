//
//  RoomEncryptionContent.swift
//
//
//  Created by Charles Wright on 5/18/22.
//

import Foundation

/// m.room.encryption: https://spec.matrix.org/v1.5/client-server-api/#mroomencryption
public struct RoomEncryptionContent: Codable {
    public static let defaultRotationPeriodMs: UInt64 = 604800000
    public static let defaultRotationPeriodMsgs: UInt64 = 100
    
    public enum Algorithm: String, Codable {
        case megolmV1AesSha2 = "m.megolm.v1.aes-sha2"
    }
    public let algorithm: Algorithm
    public let rotationPeriodMs: UInt64?
    public let rotationPeriodMsgs: UInt64?
    
    public init() {
        algorithm = .megolmV1AesSha2
        rotationPeriodMs = RoomEncryptionContent.defaultRotationPeriodMs  // FIXME: Does it really make sense to rotate this frequently?  We're just going to store all the keys on the server anyway, protected by a single symmetric backup key.  WTF?
        rotationPeriodMsgs = RoomEncryptionContent.defaultRotationPeriodMsgs
    }
    
    public init(algorithm: Algorithm, rotationPeriodMs: UInt64, rotationPeriodMsgs: UInt64) {
        self.algorithm = algorithm
        self.rotationPeriodMs = rotationPeriodMs
        self.rotationPeriodMsgs = rotationPeriodMsgs
    }
    
    public enum CodingKeys: String, CodingKey {
        case algorithm
        case rotationPeriodMs = "rotation_period_ms"
        case rotationPeriodMsgs = "rotation_period_msgs"
    }
}
