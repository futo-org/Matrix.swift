//
//  StrippedStateEventRecord.swift
//  
//
//  Created by Charles Wright on 2/27/23.
//

import Foundation
import AnyCodable
import GRDB

struct StrippedStateEventRecord: Codable {
    let roomId: RoomId
    let sender: UserId
    let stateKey: String
    let type: String
    let content: Codable

    public enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case sender
        case stateKey = "state_key"
        case type
        case content
    }
    
    public enum Columns: String, ColumnExpression {
        case roomId = "room_id"
        case sender
        case stateKey = "state_key"
        case type
        case content
    }
    
    public var description: String {
        return """
               StrippedStateEventRecord: {roomId: \(roomId), sender: \(sender), \
               stateKey:\(stateKey), type:\(type), content:\(content)}
               """
    }
    
    public init(from event: StrippedStateEvent, in roomId: RoomId) {
        self.roomId = roomId
        self.sender = event.sender
        self.stateKey = event.stateKey
        self.type = event.type
        self.content = event.content
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.roomId = try container.decode(RoomId.self, forKey: .roomId)
        self.sender = try container.decode(UserId.self, forKey: .sender)
        self.stateKey = try container.decode(String.self, forKey: .stateKey)
        self.type = try container.decode(String.self, forKey: .type)
        
        self.content = try Matrix.decodeEventContent(of: self.type, from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(sender, forKey: .sender)
        try container.encode(stateKey, forKey: .stateKey)
        try container.encode(type, forKey: .type)
        try container.encode(AnyCodable(content), forKey: .content)
    }
}

extension StrippedStateEventRecord: FetchableRecord, TableRecord {
    static var databaseTableName: String = "stripped_state"
}

extension StrippedStateEventRecord: PersistableRecord { }
