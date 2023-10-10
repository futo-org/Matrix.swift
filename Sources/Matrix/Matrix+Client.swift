//
//  Matrix+API.swift
//  Circles
//
//  Created by Charles Wright on 6/15/22.
//

import Foundation
import os
#if !os(macOS)
import UIKit
#else
import AppKit
#endif

import AnyCodable

extension Matrix {
    
@available(macOS 12.0, *)
public class Client {
    public var creds: Matrix.Credentials
    public var baseUrl: URL
    public let version: String
    private var apiUrlSession: URLSession   // For making API calls
    private var mediaUrlSession: URLSession // For downloading media
    private var mediaCache: URLCache        // For downloading media
    private var mediaDownloadTasks: [MXC: Task<URL,Swift.Error>] // For downloading media
    
    private var logger: os.Logger
    
    // MARK: Init
    
    public init(creds: Matrix.Credentials) async throws {
        self.version = "v3"
        let logger = os.Logger(subsystem: "matrix", category: "client")
        self.logger = logger
        
        logger.debug("Creating a new Matrix Client for user \(creds.userId)")
        
        if let wk = creds.wellKnown {
            self.creds = creds
            self.baseUrl = URL(string: wk.homeserver.baseUrl)!
        } else {
            let wk = try await Matrix.fetchWellKnown(for: creds.userId.domain)
            self.creds = Matrix.Credentials(userId: creds.userId,
                                            accessToken: creds.accessToken,
                                            deviceId: creds.deviceId,
                                            wellKnown: wk)
            self.baseUrl = URL(string: wk.homeserver.baseUrl)!
        }
        
        logger.debug("Setting up URLSession for API calls")
        let apiConfig = URLSessionConfiguration.default
        apiConfig.httpAdditionalHeaders = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Bearer \(creds.accessToken)",
        ]
        apiConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        apiConfig.httpMaximumConnectionsPerHost = 4 // Default is 6 but we're getting some 429's from Synapse...
        self.apiUrlSession = URLSession(configuration: apiConfig)
        
        logger.debug("Setting up URLSession for media access")
        // https://developer.apple.com/documentation/foundation/urlcache
        // Unfortunately this thing kind of sucks, and doesn't persist across restarts of the app
        
        let topCacheDirectory = try FileManager.default.url(for: .cachesDirectory,
                                                            in: .userDomainMask,
                                                            appropriateFor: nil,
                                                            create: true)
        let applicationName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "matrix.swift"

        let mediaCacheDir = topCacheDirectory
            .appendingPathComponent(".matrix")
            .appendingPathComponent(applicationName)
            .appendingPathComponent(creds.userId.stringValue)
            .appendingPathComponent(creds.deviceId)
            .appendingPathComponent("urlcache")
        logger.debug("Media cache dir = \(mediaCacheDir)")
        do {
            logger.debug("Ensuring media cache dir exists")
            try FileManager.default.createDirectory(at: mediaCacheDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create media cache dir")
            throw Matrix.Error("Failed to create media cache dir")
        }

        logger.debug("Creating media URL session config")
        let mediaConfig = URLSessionConfiguration.default
        mediaConfig.httpAdditionalHeaders = [
            "Authorization": "Bearer \(creds.accessToken)",
        ]
        logger.debug("Creating URL cache")
        let cache = URLCache(memoryCapacity: 64*1024*1024, diskCapacity: 512*1024*1024, directory: mediaCacheDir)
        mediaConfig.urlCache = cache
        mediaConfig.requestCachePolicy = .returnCacheDataElseLoad
        logger.debug("Creating media URL session")
        self.mediaUrlSession = URLSession(configuration: mediaConfig)
        self.mediaCache = cache
        self.mediaDownloadTasks = [:]
        
        logger.debug("Done with init()")
    }
    
    // MARK: API Call
    public func call(method: String,
                     path: String,
                     params: [String:String]? = nil,
                     body: Codable? = nil,
                     expectedStatuses: [Int] = [200]
    ) async throws -> (Data, HTTPURLResponse) {
        if let stringBody = body as? String {
            print("APICALL\t\(self.creds.userId) String request body = \n\(stringBody)")
            let data = stringBody.data(using: .utf8)!
            return try await call(method: method, path: path, params: params, bodyData: data, expectedStatuses: expectedStatuses)
        } else if let codableBody = body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let encodedBody = try encoder.encode(AnyCodable(codableBody))
            print("APICALL\t\(self.creds.userId) Raw request body = \n\(String(decoding: encodedBody, as: UTF8.self))")
            return try await call(method: method, path: path, params: params, bodyData: encodedBody, expectedStatuses: expectedStatuses)
        } else {
            let noBody: Data? = nil
            return try await call(method: method, path: path, params: params, bodyData: noBody, expectedStatuses: expectedStatuses)
        }

    }
    
    public func call(method: String,
                     path: String,
                     params: [String:String]? = nil,
                     bodyData: Data?=nil,
                     expectedStatuses: [Int] = [200]
    ) async throws -> (Data, HTTPURLResponse) {
        print("APICALL\t\(self.creds.userId) Calling \(method) \(path)")

        //let url = URL(string: path, relativeTo: baseUrl)!.appending(queryItems: queryItems)
        var components = URLComponents(url: URL(string: path, relativeTo: self.baseUrl)!, resolvingAgainstBaseURL: true)!
        if let urlParams = params {
            let queryItems: [URLQueryItem] = urlParams.map { (key,value) -> URLQueryItem in
                URLQueryItem(name: key, value: value)
            }
            components.queryItems = queryItems
        }
        let url = components.url!
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
               
        var slowDown = true
        var delayNs: UInt64 = 1_000_000_000
        var count = 0
        
        repeat {
            let (data, response) = try await apiUrlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse
            else {
                let msg = "Couldn't handle HTTP response"
                print("APICALL\t\(self.creds.userId) \(msg)")
                throw Matrix.Error(msg)
            }
            
            if httpResponse.statusCode == 429 {
                slowDown = true

                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                if let rateLimitError = try? decoder.decode(Matrix.RateLimitError.self, from: data),
                   let delayMs = rateLimitError.retryAfterMs
                {
                    delayNs = 1_000_000 * UInt64(delayMs)
                } else {
                    delayNs *= 2
                }
                
                print("APICALL\t\(self.creds.userId) Got 429 error...  Waiting \(delayNs) nanosecs and then retrying")
                try await Task.sleep(nanoseconds: delayNs)
                
                count += 1
            } else {
                slowDown = false
                guard expectedStatuses.contains(httpResponse.statusCode)
                else {
                    let msg = "Matrix API call \(method) \(path) rejected with status \(httpResponse.statusCode)"
                    print("APICALL\t\(self.creds.userId) \(msg)")
                    let decoder = JSONDecoder()
                    if let errorResponse = try? decoder.decode(Matrix.ErrorResponse.self, from: data) {
                        print("APICALL\terrcode = \(errorResponse.errcode)\terror = \(errorResponse.error)")
                    } else {
                        let errorString = String(decoding: data, as: UTF8.self)
                        print("APICALL\tGot error response = \(errorString)")
                    }
                    throw Matrix.Error(msg)
                }
                print("APICALL\tGot response with status \(httpResponse.statusCode)")
                
                return (data, httpResponse)
            }
            
        } while slowDown && count < 5
        
        throw Matrix.Error("API call failed")
    }
    
    // MARK: My User Profile
    
    // https://spec.matrix.org/v1.2/client-server-api/#put_matrixclientv3profileuseriddisplayname
    public func setMyDisplayName(_ name: String) async throws {
        let (_, _) = try await call(method: "PUT",
                                    path: "/_matrix/client/\(version)/profile/\(creds.userId)/displayname",
                                    body: [
                                        "displayname": name,
                                    ])
    }
    
    public func setMyAvatarImage(_ image: NativeImage) async throws {
        // First upload the image
        let mxc = try await uploadImage(image, maxSize: CGSize(width: 256, height: 256))
        // Then set that as our avatar
        try await setMyAvatarUrl(mxc)
    }

    
    public func setMyAvatarUrl(_ mxc: MXC) async throws {
        let (_,_) = try await call(method: "PUT",
                                   path: "_matrix/client/\(version)/profile/\(creds.userId)/avatar_url",
                                   body: [
                                     "avatar_url": "\(mxc)",
                                   ])
    }
    
    public func setMyStatus(message: String) async throws {
        let body = [
            "presence": "online",
            "status_msg": message,
        ]
        try await call(method: "PUT", path: "/_matrix/client/\(version)/presence/\(creds.userId)/status", body: body)
    }
    
    // MARK: Other User Profiles
    
    public func getDisplayName(userId: UserId) async throws -> String? {
        let path = "/_matrix/client/\(version)/profile/\(userId)/displayname"
        let (data, response) = try await call(method: "GET", path: path)
        
        struct ResponseBody: Codable {
            var displayname: String?
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        guard let responseBody = try? decoder.decode(ResponseBody.self, from: data)
        else {
            return nil
        }
        
        return responseBody.displayname
    }
    
    // https://spec.matrix.org/v1.2/client-server-api/#get_matrixclientv3profileuseridavatar_url
    public func getAvatarUrl(userId: UserId) async throws -> MXC? {
        let path = "/_matrix/client/\(version)/profile/\(userId)/avatar_url"
        let (data, response) = try await call(method: "GET", path: path)
        
        struct ResponseBody: Codable {
            var avatarUrl: MXC?
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        guard let responseBody = try? decoder.decode(ResponseBody.self, from: data)
        else {
            return nil
        }
        
        return responseBody.avatarUrl
    }
    
    public func getAvatarImage(userId: UserId) async throws -> Matrix.NativeImage? {
        // Download the bytes from the given uri
        guard let mxc = try await getAvatarUrl(userId: userId)
        else {
            let msg = "Couldn't get mxc:// URI"
            print("USER\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        let data = try await downloadData(mxc: mxc)
        
        // Create a UIImage or NSImage as appropriate
        let image = Matrix.NativeImage(data: data)
        
        // return the UIImage
        return image
    }

    
    public func getProfileInfo(userId: UserId) async throws -> (String?,MXC?) {
               
        let (data, response) = try await call(method: "GET", path: "/_matrix/client/\(version)/profile/\(userId)")
        
        struct UserProfileInfo: Codable {
            let displayName: String?
            let avatarUrl: MXC?
            
            enum CodingKeys: String, CodingKey {
                case displayName = "displayname"
                case avatarUrl = "avatar_url"
            }
        }
        
        let decoder = JSONDecoder()
        guard let profileInfo: UserProfileInfo = try? decoder.decode(UserProfileInfo.self, from: data)
        else {
            let msg = "Failed to decode user profile"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        return (profileInfo.displayName, profileInfo.avatarUrl)
    }
    
    // MARK: User Directory
    // https://spec.matrix.org/v1.6/client-server-api/#user-directory
    
    public func searchUserDirectory(term: String, limit: Int = 10) async throws -> [UserId] {
        let path = "/_matrix/client/v3/user_directory/search"
        let body = [
            "limit": "\(limit)",
            "search_term": term,
        ]
        let (data, response) = try await call(method: "POST", path: path, body: body)
        
        struct UserDirectorySearchResult: Codable {
            var limited: Bool
            var results: [User]
            
            struct User: Codable {
                var avatarUrl: MXC?
                var displayname: String?
                var userId: UserId
                
                enum CodingKeys: String, CodingKey {
                    case avatarUrl = "avatar_url"
                    case displayname = "display_name"
                    case userId = "user_id"
                }
            }
        }
        let decoder = JSONDecoder()
        let result = try decoder.decode(UserDirectorySearchResult.self, from: data)
        return result.results.compactMap {
            $0.userId
        }
    }
    
    
    // MARK: Account Data
    
    // https://spec.matrix.org/v1.2/client-server-api/#get_matrixclientv3useruseridaccount_datatype
    public func getAccountData<T>(for eventType: String, of dataType: T.Type) async throws -> T? where T: Decodable {
        let path = "/_matrix/client/v3/user/\(creds.userId)/account_data/\(eventType)"
        let (data, response) = try await call(method: "GET", path: path, expectedStatuses: [200,404])
        
        // If we get a 404 it's no big deal.  Just means that the user doesn't have any account data of that type.
        // Just return nil and move on with life.
        if response.statusCode == 404 {
            return nil
        }
        
        // Otherwise we know the status code must be 200
        // Look at the data that we received, decode it, and return the result
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let content = try decoder.decode(dataType, from: data)
        
        return content
    }
    
    // https://spec.matrix.org/v1.6/client-server-api/#put_matrixclientv3useruseridaccount_datatype
    public func putAccountData(_ content: Codable, for eventType: String) async throws {
        let path = "/_matrix/client/v3/user/\(creds.userId)/account_data/\(eventType)"
        let (data, response) = try await call(method: "PUT", path: path, body: content)
    }
    
    // MARK: Devices
    
    public func getDevices() async throws -> [Matrix.MyDevice] {
        let path = "/_matrix/client/\(version)/devices"
        let (data, response) = try await call(method: "GET", path: path)
        
        struct DeviceInfo: Codable {
            var deviceId: String
            var displayName: String?
            var lastSeenIp: String?
            var lastSeenTs: Int?
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let infos = try? decoder.decode([DeviceInfo].self, from: data)
        else {
            let msg = "Couldn't decode device info"
            print("DEVICES\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        let devices = infos.map {
            Matrix.MyDevice(/*matrix: self,*/ deviceId: $0.deviceId, displayName: $0.displayName, lastSeenIp: $0.lastSeenIp, lastSeenUnixMs: $0.lastSeenTs)
        }
        
        return devices
    }
    
    public func getDevice(deviceId: String) async throws -> Matrix.MyDevice {
        let path = "/_matrix/client/v3/devices/\(deviceId)"
        let (data, response) = try await call(method: "GET", path: path)
        
        struct DeviceInfo: Codable {
            var deviceId: String
            var displayName: String?
            var lastSeenIp: String?
            var lastSeenTs: Int?
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let info = try? decoder.decode(DeviceInfo.self, from: data)
        else {
            let msg = "Couldn't decode info for device \(deviceId)"
            print("DEVICES\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        let device = Matrix.MyDevice(/*matrix: self,*/ deviceId: info.deviceId, displayName: info.displayName, lastSeenIp: info.lastSeenIp, lastSeenUnixMs: info.lastSeenTs)
        
        return device
    }
    
    public func setDeviceDisplayName(deviceId: String, displayName: String) async throws {
        let path = "/_matrix/client/\(version)/devices/\(deviceId)"
        let (data, response) = try await call(method: "PUT",
                                              path: path,
                                              body: [
                                                "display_name": displayName
                                              ])
    }
    
    // https://spec.matrix.org/v1.3/client-server-api/#delete_matrixclientv3devicesdeviceid
    // FIXME This must support UIA.  Return a UIAASession???
    public func deleteDevice(deviceId: String) async throws -> UIAuthSession? {
        let path = "/_matrix/client/v3/devices/\(deviceId)"
        let (data, response) = try await call(method: "DELETE",
                                              path: path,
                                              body: [String:String](),
                                              expectedStatuses: [200,401])
        switch response.statusCode {
        case 200:
            // No need to do UIA.  Maybe we recently authenticated ourselves for another API call?
            // Anyway, we're happy.  Tell the caller that we're good to go; no more work to do.
            return nil
        case 401:
            // We need to auth
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let uiaState = try? decoder.decode(UIAA.SessionState.self, from: data)
            else {
                let msg = "Could not decode UIA info"
                print("API\t\(msg)")
                throw Matrix.Error(msg)
            }
            let uiaSession = UIAuthSession(method: "DELETE", url: URL(string: path, relativeTo: baseUrl)!, credentials: creds, requestDict: [:])
            uiaSession.state = .connected(uiaState)
            
            return uiaSession
        default:
            throw Matrix.Error("Got unexpected response")
        }
    }
    
    // MARK: Rooms
    
    // https://spec.matrix.org/v1.2/client-server-api/#get_matrixclientv3joined_rooms
    public func getJoinedRoomIds() async throws -> [RoomId] {
        
        let (data, response) = try await call(method: "GET", path: "/_matrix/client/\(version)/joined_rooms")
        
        struct ResponseBody: Codable {
            var joinedRooms: [RoomId]
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        guard let responseBody = try? decoder.decode(ResponseBody.self, from: data)
        else {
            let msg = "Failed to decode list of joined rooms"
            print("GETJOINEDROOMS\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        return responseBody.joinedRooms
    }
    
    // https://spec.matrix.org/v1.2/client-server-api/#post_matrixclientv3createroom
    public func createRoom(name: String,
                    type: String? = nil,
                    encrypted: Bool = true,
                    invite userIds: [UserId] = [],
                    direct: Bool = false,
                    joinRule: RoomJoinRuleContent.JoinRule? = nil,
                    powerLevelContentOverride: RoomPowerLevelsContent? = nil
    ) async throws -> RoomId {
        print("CREATEROOM\tCreating room with name=[\(name)] and type=[\(type ?? "(none)")]")
        
        struct CreateRoomRequestBody: Codable {
            var creation_content: [String: String] = [:]
            
            struct StateEvent: Matrix.Event {
                var content: Codable
                var stateKey: String
                var type: String
                
                enum CodingKeys: String, CodingKey {
                    case content
                    case stateKey = "state_key"
                    case type
                }
                
                init(type: String, stateKey: String = "", content: Codable) {
                    self.type = type
                    self.stateKey = stateKey
                    self.content = content
                }
                
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.stateKey = try container.decode(String.self, forKey: .stateKey)
                    self.type = try container.decode(String.self, forKey: .type)
                    //let minimal = try MinimalEvent(from: decoder)
                    //self.content = minimal.content
                    self.content = try Matrix.decodeEventContent(of: type, from: decoder)
                }
                
                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(stateKey, forKey: .stateKey)
                    try container.encode(type, forKey: .type)
                    try container.encode(content, forKey:.content)
                }
            }
            var initial_state: [StateEvent]?
            var invite: [String]?
            var invite_3pid: [String]?
            var is_direct: Bool = false
            var name: String?
            var power_level_content_override: RoomPowerLevelsContent?
            enum Preset: String, Codable {
                case private_chat
                case public_chat
                case trusted_private_chat
            }
            var preset: Preset = .private_chat
            var room_alias_name: String?
            var room_version: String = "10"
            var topic: String?
            enum Visibility: String, Codable {
                case pub = "public"
                case priv = "private"
            }
            var visibility: Visibility = .priv
            
            init(name: String, type: String? = nil, encrypted: Bool,
                 joinRule: RoomJoinRuleContent.JoinRule? = nil,
                 powerLevelContentOverride: RoomPowerLevelsContent? = nil
            ) {
                self.name = name
                
                // Set up the initial state
                var stateEvents = [StateEvent]()
                if let rule = joinRule {
                    let joinRuleEvent = StateEvent(type: M_ROOM_JOIN_RULES,
                                                   stateKey: "",
                                                   content: RoomJoinRuleContent(joinRule: rule))
                    stateEvents.append(joinRuleEvent)
                }
                if encrypted {
                    let encryptionEvent = StateEvent(
                        type: M_ROOM_ENCRYPTION,
                        stateKey: "",
                        content: RoomEncryptionContent()
                    )
                    stateEvents.append(encryptionEvent)
                }
                if !stateEvents.isEmpty {
                    self.initial_state = stateEvents
                }
                
                if let roomType = type {
                    self.creation_content = ["type": roomType]
                }
                
                if let powerLevels = powerLevelContentOverride {
                    self.power_level_content_override = powerLevels
                }
            }
        }
        let requestBody = CreateRoomRequestBody(name: name, type: type, encrypted: encrypted,
                                                joinRule: joinRule,
                                                powerLevelContentOverride: powerLevelContentOverride)
        
        print("CREATEROOM\tSending Matrix API request...")
        let (data, response) = try await call(method: "POST",
                                    path: "/_matrix/client/\(version)/createRoom",
                                    body: requestBody)
        print("CREATEROOM\tGot Matrix API response")
        
        struct CreateRoomResponseBody: Codable {
            var roomId: String
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let responseBody = try? decoder.decode(CreateRoomResponseBody.self, from: data)
        else {
            let msg = "Failed to decode response from server"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        return RoomId(responseBody.roomId)!
    }
    
    public func sendStateEvent(to roomId: RoomId,
                        type: String,
                        content: Codable,
                        stateKey: String = ""
    ) async throws -> EventId {
        print("SENDSTATE\tSending state event of type [\(type)] to room [\(roomId)]")
        
        let (data, response) = try await call(method: "PUT",
                                              path: "/_matrix/client/\(version)/rooms/\(roomId)/state/\(type)/\(stateKey)",
                                              body: content)
        struct ResponseBody: Codable {
            var eventId: EventId
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let responseBody = try? decoder.decode(ResponseBody.self, from: data)
        else {
            let msg = "Failed to decode state event response"
            print(msg)
            throw Matrix.Error(msg)
        }
    
        return responseBody.eventId
    }
    
    // https://spec.matrix.org/v1.5/client-server-api/#put_matrixclientv3roomsroomidsendeventtypetxnid
    public func sendMessageEvent(to roomId: RoomId,
                          type: String,
                          content: Codable
    ) async throws -> EventId {
        print("SENDMESSAGE\tSending message event of type [\(type)] to room [\(roomId)]")

        let txnId = "\(UInt16.random(in: UInt16.min...UInt16.max))"
        let (data, response) = try await call(method: "PUT",
                                              path: "/_matrix/client/\(version)/rooms/\(roomId)/send/\(type)/\(txnId)",
                                              body: content)
        
        struct ResponseBody: Codable {
            var eventId: EventId
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let responseBody = try? decoder.decode(ResponseBody.self, from: data)
        else {
            let msg = "Failed to decode state event response"
            print(msg)
            throw Matrix.Error(msg)
        }
    
        return responseBody.eventId
    }
    
    // "m.reaction relationships are not currently specified, but are shown here for their conceptual place in a threaded DAG. They are currently proposed as MSC2677."
    // See MSC2677: https://github.com/matrix-org/matrix-spec-proposals/pull/2677
    public func addReaction(reaction: String,
                            to eventId: EventId,
                            in roomId: RoomId
    ) async throws -> EventId {
        let content = ReactionContent(eventId: eventId, reaction: reaction)
        return try await sendMessageEvent(to: roomId, type: M_REACTION, content: content)
    }
    
    public func sendRedactionEvent(to roomId: RoomId,
                            for eventId: EventId,
                            reason: String? = nil
    ) async throws -> EventId {
        print("REDACT\tSending redaction for event [\(eventId)] to room [\(roomId)]")
        
        let txnId = "\(UInt16.random(in: UInt16.min...UInt16.max))"
        let (data, response) = try await call(method: "PUT",
                                              path: "/_matrix/client/\(version)/rooms/\(roomId)/redact/\(eventId)/\(txnId)",
                                              body: ["reason": reason])
        
        struct ResponseBody: Codable {
            var eventId: EventId
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let responseBody = try? decoder.decode(ResponseBody.self, from: data)
        else {
            let msg = "Failed to decode state event response"
            print(msg)
            throw Matrix.Error(msg)
        }
    
        return responseBody.eventId
    }
    
    public func sendReport(for eventId: EventId,
                    in roomId: RoomId,
                    score: Int,
                    reason: String? = nil
    ) async throws {
        print("REPORT\tSending report for event [\(eventId)] in room [\(roomId)]")
        
        let txnId = "\(UInt16.random(in: UInt16.min...UInt16.max))"
        let (data, response) = try await call(method: "PUT",
                                              path: "/_matrix/client/\(version)/rooms/\(roomId)/report/\(eventId)/\(txnId)",
                                              body: [
                                                "reason": AnyCodable(reason),
                                                "score": AnyCodable(score)
                                              ])
    }
    
    
    // MARK: Room tags
    
    public func addTag(roomId: RoomId, tag: String, order: Float? = nil) async throws {
        let path = "/_matrix/client/\(version)/user/\(creds.userId)/rooms/\(roomId)/tags/\(tag)"
        let body = ["order": order ?? Float.random(in: 0.0 ..< 1.0)]
        let _ = try await call(method: "PUT", path: path, body: body)
    }
    
    private func getTagEventContent(roomId: RoomId) async throws -> TagContent {
        let path = "/_matrix/client/\(version)/user/\(creds.userId)/rooms/\(roomId)/tags"
        let (data, response) = try await call(method: "GET", path: path, body: nil)
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let tagContent = try? decoder.decode(TagContent.self, from: data)
        else {
            let msg = "Failed to decode room tag content"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        return tagContent
    }
    
    public func getTags(roomId: RoomId) async throws -> [String] {
        let tagContent = try await getTagEventContent(roomId: roomId)
        let tags: [String] = [String](tagContent.tags.keys)
        return tags
    }
    
    // MARK: Room Metadata

    public func setAvatarImage(roomId: RoomId,
                               image: NativeImage,
                               size: CGSize = .init(width: 400, height: 400),
                               quality: CGFloat = .init(0.70)
    ) async throws -> (NativeImage,MXC) {
        
        guard let scaledImage = image.downscale(to: size)
        else {
            let msg = "Failed to downscale image"
            print(msg)
            throw Matrix.Error(msg)
        }
        logger.debug("Scaled image down to (\(scaledImage.size.width),\(scaledImage.size.height))")
        
        guard let jpegData = scaledImage.jpegData(compressionQuality: quality)
        else {
            let msg = "Failed to compress image"
            print(msg)
            throw Matrix.Error(msg)
        }
        logger.debug("Compressed image down to \(Double(jpegData.count)/1024) KB")
        
        guard let mxc = try? await uploadData(data: jpegData, contentType: "image/jpeg") else {
            let msg = "Failed to upload image for room avatar"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        let info = mImageInfo(h: Int(scaledImage.size.height),
                              w: Int(scaledImage.size.width),
                              mimetype: "image/jpeg",
                              size: jpegData.count)
        
        let _ = try await sendStateEvent(to: roomId, type: M_ROOM_AVATAR, content: RoomAvatarContent(url: mxc, info: info))
        
        return (scaledImage,mxc)
    }

    
    public func getAvatarImage(roomId: RoomId) async throws -> Matrix.NativeImage? {
        guard let content = try? await getRoomState(roomId: roomId, eventType: M_ROOM_AVATAR) as? RoomAvatarContent
        else {
            // No avatar for this room???
            return nil
        }
        
        let data = try await downloadData(mxc: content.url)
        let image = Matrix.NativeImage(data: data)
        return image
    }
    
    public func setTopic(roomId: RoomId, topic: String) async throws {
        let _ = try await sendStateEvent(to: roomId, type: M_ROOM_TOPIC, content: ["topic": topic])
    }
    
    public func setRoomName(roomId: RoomId, name: String) async throws {
        try await sendStateEvent(to: roomId, type: M_ROOM_NAME, content: RoomNameContent(name: name))
    }
    
    public func getRoomName(roomId: RoomId) async throws -> String? {
        guard let content = try await getRoomState(roomId: roomId, eventType: M_ROOM_NAME) as? RoomNameContent
        else {
            return nil
        }
        return content.name
    }
    
    // MARK: Room Messages
    
    // https://spec.matrix.org/v1.2/client-server-api/#get_matrixclientv3roomsroomidmessages
    // Good news!  `from` is no longer required as of v1.3 (June 2022),
    // so we no longer have to call /sync before fetching messages.
    public func getMessages(roomId: RoomId,
                            forward: Bool = false,
                            from startToken: String? = nil,
                            to endToken: String? = nil,
                            limit: UInt? = 25
    ) async throws -> RoomMessagesResponseBody {
        let path = "/_matrix/client/v3/rooms/\(roomId)/messages"
        var params: [String:String] = [
            "dir" : forward ? "f" : "b",
        ]
        if let start = startToken {
            params["from"] = start
        }
        if let end = endToken {
            params["to"] = end
        }
        if let limit = limit {
            params["limit"] = "\(limit)"
        }
        let (data, response) = try await call(method: "GET", path: path, params: params)
        
        let decoder = JSONDecoder()
        
        let responseBody = try decoder.decode(RoomMessagesResponseBody.self, from: data)
        
        return responseBody
    }
    
    // MARK: Relations
    
    // https://spec.matrix.org/v1.6/client-server-api/#get_matrixclientv1roomsroomidrelationseventidreltype
    open func getRelatedMessages(roomId: RoomId,
                                 eventId: EventId,
                                 relType: String,
                                 from startToken: String? = nil,
                                 to endToken: String? = nil,
                                 limit: UInt? = 25
    ) async throws -> RelatedMessagesResponseBody {
        let path = "/_matrix/client/v1/rooms/\(roomId)/relations/\(eventId)/\(relType)"
        var params: [String:String] = [
            "dir" : "b",
        ]
        if let start = startToken {
            params["from"] = start
        }
        if let end = endToken {
            params["to"] = end
        }
        if let limit = limit {
            params["limit"] = "\(limit)"
        }
        let (data, response) = try await call(method: "GET", path: path, params: params)
        
        let decoder = JSONDecoder()
        
        let responseBody = try decoder.decode(RelatedMessagesResponseBody.self, from: data)
        
        return responseBody
    }
    
    
    // MARK: Threads
    
    // https://spec.matrix.org/v1.6/client-server-api/#querying-threads-in-a-room
    public func getThreadRoots(roomId: RoomId,
                               from startToken: String? = nil,
                               include: String? = nil,
                               limit: UInt? = 25
    ) async throws -> RelatedMessagesResponseBody {
        let path = "/_matrix/client/v1/rooms/\(roomId)/threads"
        var params: [String:String] = [:]
        if let start = startToken {
            params["start"] = start
        }
        if let include = include {
            params["include"] = include
        }
        if let limit = limit {
            params["limit"] = "\(limit)"
        }
        let (data, response) = try await call(method: "GET", path: path, params: params)
        
        let decoder = JSONDecoder()
        
        guard let responseBody = try? decoder.decode(RelatedMessagesResponseBody.self, from: data)
        else {
            let msg = "Failed to decode GET /threads response body"
            logger.error("\(msg)")
            throw Matrix.Error(msg)
        }
        
        return responseBody
    }
    
    open func getThreadedMessages(roomId: RoomId,
                                  threadId: EventId,
                                  from startToken: String? = nil,
                                  to endToken: String? = nil,
                                  limit: UInt? = 25
    ) async throws -> RelatedMessagesResponseBody {
        return try await getRelatedMessages(roomId: roomId,
                                            eventId: threadId,
                                            relType: M_THREAD,
                                            from: startToken,
                                            to: endToken,
                                            limit: limit)
    }
    
    
    // MARK: Room State
    
    // https://spec.matrix.org/v1.2/client-server-api/#get_matrixclientv3roomsroomidjoined_members
    public func getJoinedMembers(roomId: RoomId) async throws -> [UserId] {
        let path = "/_matrix/client/\(version)/rooms/\(roomId)/joined_members"
        let (data, response) = try await call(method: "GET", path: path)
        let string = String(decoding: data, as: UTF8.self)
        print("getJoinedMembers:\t\(self.creds.userId) Got response = \(string)")
        
        struct ResponseBody: Codable {
            struct RoomMember: Codable {
                var avatarUrl: String?
                var displayName: String?
                enum CodingKeys: String, CodingKey {
                    case avatarUrl = "avatar_url"
                    case displayName = "displayname"
                }
            }
            var joined: [UserId: RoomMember]
        }
        
        let decoder = JSONDecoder()
        //decoder.keyDecodingStrategy = .convertFromSnakeCase
        let responseBody = try decoder.decode(ResponseBody.self, from: data)
        let users = [UserId](responseBody.joined.keys)
        return users
    }
    
    // https://spec.matrix.org/v1.2/client-server-api/#get_matrixclientv3roomsroomidstate
    // FIXME This actually returns [ClientEvent] but we're returning the version without the roomid in order to match /sync
    // It's possible that we're introducing a vulnerability here -- The server could return events from other rooms
    // OTOH it can already do that when we call /sync, so what's new?
    public func getRoomStateEvents(roomId: RoomId) async throws -> [ClientEventWithoutRoomId] {
        let path = "/_matrix/client/\(version)/rooms/\(roomId)/state"
        
        let (data, response) = try await call(method: "GET", path: path)

        let stringResponse = String(data: data, encoding: .utf8)!
        print("Got state events:\n\(stringResponse)")
        
        let decoder = JSONDecoder()
        let events = try decoder.decode([ClientEventWithoutRoomId].self, from: data)
        return events
    }
    
    public func getRoomState(roomId: RoomId, eventType: String, with stateKey: String = "") async throws -> Codable {
        let path = "/_matrix/client/\(version)/rooms/\(roomId)/state/\(eventType)/\(stateKey)"
        let (data, response) = try await call(method: "GET", path: path)
        
        let decoder = JSONDecoder()

        guard let codableType = Matrix.eventTypes[eventType],
              let content = try? decoder.decode(codableType.self, from: data)
        else {
            let msg = "Couldn't decode room state for event type \(eventType)"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        return content
    }
    
    public func inviteUser(roomId: RoomId, userId: UserId, reason: String? = nil) async throws {
        let path = "/_matrix/client/\(version)/rooms/\(roomId)/invite"
        let (data, response) = try await call(method: "POST",
                                              path: path,
                                              body: [
                                                "user_id": "\(userId)",
                                                "reason": reason
                                              ])
        // FIXME: Parse and handle any Matrix 400 or 403 errors
    }
    
    public func kickUser(roomId: RoomId, userId: UserId, reason: String? = nil) async throws {
        let path = "/_matrix/client/\(version)/rooms/\(roomId)/kick"
        let (data, response) = try await call(method: "POST",
                                              path: path,
                                              body: [
                                                "user_id": "\(userId)",
                                                "reason": reason
                                              ])
    }
    
    public func banUser(roomId: RoomId, userId: UserId, reason: String? = nil) async throws {
        let path = "/_matrix/client/\(version)/rooms/\(roomId)/ban"
        let (data, response) = try await call(method: "POST",
                                              path: path,
                                              body: [
                                                "user_id": "\(userId)",
                                                "reason": reason
                                              ])
    }
    
    public func join(roomId: RoomId, reason: String? = nil) async throws {
        let path = "/_matrix/client/\(version)/rooms/\(roomId)/join"
        let (data, response) = try await call(method: "POST",
                                              path: path,
                                              body: [
                                                "reason": reason
                                              ])
    }
    
    public func knock(roomId: RoomId, reason: String? = nil) async throws {
        let path = "/_matrix/client/\(version)/knock/\(roomId)"
        let (data, response) = try await call(method: "POST",
                                              path: path,
                                              body: [
                                                "reason": reason
                                              ])
    }
    
    public func leave(roomId: RoomId, reason: String? = nil) async throws {
        let path = "/_matrix/client/\(version)/rooms/\(roomId)/leave"
        let (data, response) = try await call(method: "POST",
                                              path: path,
                                              body: [
                                                "reason": reason
                                              ])
    }
    
    public func forget(roomId: RoomId) async throws {
        let path = "/_matrix/client/\(version)/rooms/\(roomId)/forget"
        let (data, response) = try await call(method: "POST", path: path)
    }
    
    public func getRoomPowerLevels(roomId: RoomId) async throws -> [String: Int] {
        throw Matrix.Error("Not implemented")
    }
    
    // MARK: Spaces
    
    public func createSpace(name: String) async throws -> RoomId {
        print("CREATESPACE\tCreating space with name [\(name)]")
        let roomId = try await createRoom(name: name, type: "m.space", encrypted: false)
        return roomId
    }
    
    public func addSpaceChild(_ child: RoomId, to parent: RoomId) async throws {
        print("SPACES\tAdding [\(child)] as a child space of [\(parent)]")
        let servers = Array(Set([child.domain, parent.domain]))
        let order = (0x20 ... 0x7e).randomElement()?.description ?? "A"
        let content = SpaceChildContent(order: order, via: servers)
        let _ = try await sendStateEvent(to: parent, type: M_SPACE_CHILD, content: content, stateKey: child.description)
    }
    
    public func addSpaceParent(_ parent: RoomId, to child: RoomId, canonical: Bool = false) async throws {
        let servers = Array(Set([child.domain, parent.domain]))
        let content = SpaceParentContent(canonical: canonical, via: servers)
        let _ = try await sendStateEvent(to: child, type: M_SPACE_PARENT, content: content, stateKey: parent.description)
    }
    
    // https://spec.matrix.org/v1.5/client-server-api/#get_matrixclientv1roomsroomidhierarchy
    public func getSpaceChildren(_ roomId: RoomId) async throws -> [RoomId] {
        var children: [RoomId] = []
        var nextBatch: String? = nil
        
        repeat {
            var path = "/_matrix/client/v1/rooms/\(roomId)/hierarchy?max_depth=1"
            if let start = nextBatch {
                path += "&from=\(start)"
            }
            let (data, response) = try await call(method: "GET", path: path)
            
            struct SpaceHierarchyResponseBody: Decodable {
                var nextBatch: String?
                var rooms: [ChildRoomsChunk]
                
                enum CodingKeys: String, CodingKey {
                    case nextBatch = "next_batch"
                    case rooms
                }
                
                struct ChildRoomsChunk: Decodable {
                    var avatarUrl: MXC?
                    var canonicalAlias: String?
                    var childrenState: [StrippedStateEvent]
                    var guestCanJoin: Bool
                    var joinRule: RoomJoinRuleContent.JoinRule?
                    var name: String?
                    var numJoinedMembers: Int
                    var roomId: RoomId
                    var roomType: String?
                    var topic: String?
                    var worldReadable: Bool
                    
                    enum CodingKeys: String, CodingKey {
                        case avatarUrl = "avatar_url"
                        case canonicalAlias = "canonical_alias"
                        case childrenState = "children_state"
                        case guestCanJoin = "guest_can_join"
                        case joinRule = "join_rule"
                        case name
                        case numJoinedMembers = "num_joined_members"
                        case roomId = "room_id"
                        case roomType = "room_type"
                        case topic
                        case worldReadable = "world_readable"
                    }
                }
            }
            let decoder = JSONDecoder()
            let hierarchy = try decoder.decode(SpaceHierarchyResponseBody.self, from: data)
            nextBatch = hierarchy.nextBatch
            children += hierarchy.rooms.map { $0.roomId }
        } while nextBatch != nil
                    
        return children
    }
    
    public func removeSpaceChild(_ child: RoomId, from parent: RoomId) async throws {
        print("SPACES\tRemoving [\(child)] as a child space of [\(parent)]")
        let order = "\(0x7e)"
        let content = SpaceChildContent(order: order, via: nil)  // This stupid `via = nil` thing is the only way we have to remove a child relationship
        let _ = try await sendStateEvent(to: parent, type: M_SPACE_CHILD, content: content, stateKey: child.description)
    }
    

    
    // MARK: Media API
    
    private func getMediaHttpUrl(mxc: MXC, allowRedirect: Bool = true) -> URL? {
        let path = "/_matrix/media/v3/download/\(mxc.serverName)/\(mxc.mediaId)"
        let url = URL(string: path, relativeTo: baseUrl)
        
        if allowRedirect {
            return url?.appending(queryItems: [URLQueryItem(name: "allow_redirect", value: "true")])
        } else {
            return url
        }
    }
    
    public func downloadData(mxc: MXC, allowRedirect: Bool = true) async throws -> Data {
        guard let url = getMediaHttpUrl(mxc: mxc, allowRedirect: allowRedirect)
        else {
            logger.error("Invalid mxc:// URL \(mxc.description)")
            throw Matrix.Error("Invalid mxc:// URL \(mxc.description)")
        }
        let request = URLRequest(url: url)
        
        let (data, response) = try await mediaUrlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            let msg = "Failed to download media"
            print("DOWNLOAD\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        return data
    }
    
    public func downloadFile(mxc: MXC,
                             allowRedirect: Bool = true,
                             delegate: URLSessionDownloadDelegate? = nil
    ) async throws -> URL {
        guard let url = getMediaHttpUrl(mxc: mxc, allowRedirect: allowRedirect)
        else {
            logger.error("Invalid mxc:// URL \(mxc)")
            throw Matrix.Error("Invalid mxc:// URL \(mxc)")
        }
        
        let topLevelCachesUrl = try FileManager.default.url(for: .cachesDirectory,
                                                            in: .userDomainMask,
                                                            appropriateFor: nil,
                                                            create: true)
        let applicationName = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "matrix.swift"
        let mediaStoreDir = topLevelCachesUrl.appendingPathComponent(applicationName)
                                             .appendingPathComponent(creds.userId.stringValue)
                                             .appendingPathComponent("media")
        let domainMediaDir = mediaStoreDir.appendingPathComponent(mxc.serverName)
        try FileManager.default.createDirectory(at: domainMediaDir, withIntermediateDirectories: true)
        let cacheLocation = domainMediaDir.appendingPathComponent(mxc.mediaId)
        
        // First thing to check: Do we already have a download in progress for this file?
        if let existingTask = self.mediaDownloadTasks[mxc],
           !existingTask.isCancelled
        {
            return try await existingTask.value
        }
        
        // Second thing to check: Did we already finish downloading this file?
        if FileManager.default.isReadableFile(atPath: cacheLocation.absoluteString) {
            // If so, just return the URL
            return cacheLocation
        }
        
        // Finally, if it's really necessary, connect to the server and download the file
        let task = Task {
            let (location, response) = try await mediaUrlSession.download(from: url, delegate: delegate)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                logger.error("Failed to download media from \(url.description)")
                self.mediaDownloadTasks.removeValue(forKey: mxc)
                throw Matrix.Error("Failed to download media from \(url.description)")
            }
            logger.debug("Downloaded \(mxc) to temporary location \(location)")
            
            /*
            logger.debug("Moving \(mxc) to \(cacheLocation)")
            try FileManager.default.moveItem(at: location, to: cacheLocation)
            
            // Now that we're done running, remove ourself from the active tasks
            self.mediaDownloadTasks.removeValue(forKey: mxc)
            
            logger.debug("Successfully downloaded \(mxc)")
            return cacheLocation
            */
            self.mediaDownloadTasks.removeValue(forKey: mxc)
            return location
        }
        self.mediaDownloadTasks[mxc] = task
        return try await task.value
    }
    
    public func uploadImage(_ original: NativeImage, maxSize: CGSize, quality: CGFloat = 0.80) async throws -> MXC {
        guard let scaled = original.downscale(to: maxSize)
        else {
            let msg = "Failed to downscale image"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        let uri = try await uploadImage(scaled, quality: quality)
        return uri
    }

    
    public func uploadImage(_ image: NativeImage, quality: CGFloat = 0.80) async throws -> MXC {

        guard let jpeg = image.jpegData(compressionQuality: quality)
        else {
            let msg = "Failed to encode image as JPEG"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        return try await uploadData(data: jpeg, contentType: "image/jpeg")
    }

    
    public func uploadData(data: Data, contentType: String) async throws -> MXC {
        
        let url = URL(string: "/_matrix/media/\(version)/upload", relativeTo: baseUrl)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        
        let (responseData, response) = try await mediaUrlSession.upload(for: request, from: data)
        
        guard let httpResponse = response as? HTTPURLResponse,
              [200].contains(httpResponse.statusCode)
        else {
            let msg = "Upload request failed"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        struct UploadResponse: Codable {
            var contentUri: String
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let responseBody = try? decoder.decode(UploadResponse.self, from: responseData)
        else {
            let msg = "Failed to decode upload response"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        guard let mxc = MXC(responseBody.contentUri)
        else {
            let msg = "Could not parse MXC URL"
            print(msg)
            throw Matrix.Error(msg)
        }
        
        // FIXME: Also save a copy of our data in the download cache, so we don't have to fetch it over the network when we see it mentioned in an event
        // Looks like we just need to call .storeCachedResponse on the cache https://developer.apple.com/documentation/foundation/urlcache/1414434-storecachedresponse
        //
        // So to do that, we need to
        // * Create the CachedURLResponse
        // * Create the URLSessionDataTask
        //
        // Creating the CachedURLResponse https://developer.apple.com/documentation/foundation/cachedurlresponse
        // * .init takes a URLResponse and a Data https://developer.apple.com/documentation/foundation/cachedurlresponse/1413035-init
        //   * The URLResponse should actually be an HTTPURLResponse https://developer.apple.com/documentation/foundation/httpurlresponse
        //     * It can be instantiated from the URL, the Int status code, the HTTP version, and the header fields https://developer.apple.com/documentation/foundation/httpurlresponse/1415870-init
        //
        // Creating the URLSessionDataTask
        // * This one can be created by calling the URLSession's .dataTask(with: URL) function https://developer.apple.com/documentation/foundation/urlsession/1411554-datatask
        // * Don't worry, it doesn't actually run the task until you call .resume() on it -- We used to have lots of bugs in the old version of Circles when we would forget to do this
        
        guard let urlForCache = getMediaHttpUrl(mxc: mxc),
              let httpResponseForCache = HTTPURLResponse(url: urlForCache,
                                                         statusCode: 200,
                                                         httpVersion: nil,
                                                         headerFields: [
                                                            "Content-Type": contentType,
                                                            "Content-Length": "\(data.count)"
                                                         ])
        else {
            // hmmm somehow we failed to create what we needed for the cache.  Just return the MXC that we already received from the upload.
            print("UPLOAD\tFailed to create URL and HTTP response for the cache.  Proceeding without caching.")
            return mxc
        }
        let cachedUrlResponse = CachedURLResponse(response: httpResponseForCache, data: data)

        let dataTaskForCache = mediaUrlSession.dataTask(with: urlForCache)
        
        mediaCache.storeCachedResponse(cachedUrlResponse, for: dataTaskForCache)
        print("UPLOAD\tPre-populated uploaded data into our download cache")

        // Finally return the mxc:// URL to the caller
        return mxc
    }
    
    public func logout() async throws {
        let path = "/_matrix/client/v3/logout"
        let (data, response) = try await call(method: "POST", path: path)
    }
    
}

} // end extension Matrix
