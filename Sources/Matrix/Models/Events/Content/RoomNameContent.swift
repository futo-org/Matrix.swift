//
//  RoomNameContent.swift
//
//
//  Created by Charles Wright on 5/19/22.
//

import Foundation

/// m.room.name: https://spec.matrix.org/v1.5/client-server-api/#mroomname
public struct RoomNameContent: Codable {
    public let name: String
    
    public init(name: String) {
        self.name = name
    }
}
