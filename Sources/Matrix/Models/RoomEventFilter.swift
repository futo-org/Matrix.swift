//
//  RoomEventFilter.swift
//
//
//  Created by Charles Wright on 5/18/22.
//

import Foundation

extension Matrix {
    // https://spec.matrix.org/v1.2/client-server-api/#post_matrixclientv3useruseridfilter
    struct RoomEventFilter: Codable {
        var containsUrl: Bool?
        var includeRedundantMembers: Bool?
        var lazyLoadMembers: Bool?
        var limit: Int?
        var notRooms: [RoomId]?
        var notSenders: [UserId]?
        var notTypes: [EventType]?
        var rooms: [RoomId]?
        var senders: [UserId]?
        var types: [EventType]?
        
        enum CodingKeys: String, CodingKey {
            case containsUrl = "contains_url"
            case includeRedundantMembers = "include_redundant_members"
            case lazyLoadMembers = "lazy_load_members"
            case limit
            case notRooms = "not_rooms"
            case notSenders = "not_senders"
            case notTypes = "not_types"
            case rooms
            case senders
            case types
        }
    }
}