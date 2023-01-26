//
//  MessageContent.swift
//
//
//  Created by Charles Wright on 5/17/22.
//

import Foundation

extension Matrix {

    public struct mInReplyTo: Codable {
        public var event_id: String
        
        public init(event_id: String) {
            self.event_id = event_id
        }
    }
    public struct mRelatesTo: Codable {
        public var in_reply_to: mInReplyTo?

        public init(in_reply_to: mInReplyTo? = nil) {
            self.in_reply_to = in_reply_to
        }
        
        public enum CodingKeys: String, CodingKey {
            case in_reply_to = "m.in_reply_to"
        }
    }

    // https://matrix.org/docs/spec/client_server/r0.6.0#m-text
    public struct mTextContent: Matrix.MessageContent {
        public var msgtype: Matrix.MessageType
        public var body: String
        public var format: String?
        public var formatted_body: String?

        // https://matrix.org/docs/spec/client_server/r0.6.0#rich-replies
        // Maybe should have made the "Rich replies" functionality a protocol...
        public var relates_to: mRelatesTo?

        public init(msgtype: Matrix.MessageType, body: String, format: String? = nil,
                    formatted_body: String? = nil, relates_to: mRelatesTo? = nil) {
            self.msgtype = msgtype
            self.body = body
            self.format = format
            self.formatted_body = formatted_body
            self.relates_to = relates_to
        }
        
        public enum CodingKeys : String, CodingKey {
            case msgtype
            case body
            case format
            case formatted_body
            case relates_to = "m.relates_to"
        }
    }

    // https://matrix.org/docs/spec/client_server/r0.6.0#m-emote
    // cvw: Same as text.
    public typealias mEmoteContent = mTextContent

    // https://matrix.org/docs/spec/client_server/r0.6.0#m-notice
    // cvw: Same as text.
    public typealias mNoticeContent = mTextContent

    // https://matrix.org/docs/spec/client_server/r0.6.0#m-image
    public struct mImageContent: Matrix.MessageContent {
        public var msgtype: Matrix.MessageType
        public var body: String
        public var url: URL?
        public var info: mImageInfo
        
        public init(msgtype: Matrix.MessageType, body: String, url: URL? = nil, info: mImageInfo) {
            self.msgtype = msgtype
            self.body = body
            self.url = url
            self.info = info
        }
    }

    public struct mImageInfo: Codable {
        public var h: Int
        public var w: Int
        public var mimetype: String
        public var size: Int
        public var file: mEncryptedFile?
        public var thumbnail_url: URL?
        public var thumbnail_file: mEncryptedFile?
        public var thumbnail_info: mThumbnailInfo?
        public var blurhash: String?
        
        public init(h: Int, w: Int, mimetype: String, size: Int, file: mEncryptedFile? = nil,
                    thumbnail_url: URL? = nil, thumbnail_file: mEncryptedFile? = nil,
                    thumbnail_info: mThumbnailInfo? = nil, blurhash: String? = nil) {
            self.h = h
            self.w = w
            self.mimetype = mimetype
            self.size = size
            self.file = file
            self.thumbnail_url = thumbnail_url
            self.thumbnail_file = thumbnail_file
            self.thumbnail_info = thumbnail_info
            self.blurhash = blurhash
        }
    }

    public struct mThumbnailInfo: Codable {
        public var h: Int
        public var w: Int
        public var mimetype: String
        public var size: Int
        
        public init(h: Int, w: Int, mimetype: String, size: Int) {
            self.h = h
            self.w = w
            self.mimetype = mimetype
            self.size = size
        }
    }

    // https://matrix.org/docs/spec/client_server/r0.6.0#m-file
    public struct mFileContent: Matrix.MessageContent {
        public let msgtype: Matrix.MessageType
        public var body: String
        public var filename: String
        public var info: mFileInfo
        public var file: mEncryptedFile
        
        public init(msgtype: Matrix.MessageType, body: String, filename: String,
                    info: mFileInfo, file: mEncryptedFile) {
            self.msgtype = msgtype
            self.body = body
            self.filename = filename
            self.info = info
            self.file = file
        }
    }

    public struct mFileInfo: Codable {
        public var mimetype: String
        public var size: UInt
        public var thumbnail_file: mEncryptedFile
        public var thumbnail_info: mThumbnailInfo
        
        public init(mimetype: String, size: UInt, thumbnail_file: mEncryptedFile,
                    thumbnail_info: mThumbnailInfo) {
            self.mimetype = mimetype
            self.size = size
            self.thumbnail_file = thumbnail_file
            self.thumbnail_info = thumbnail_info
        }
    }

    // https://matrix.org/docs/spec/client_server/r0.6.0#extensions-to-m-message-msgtypes
    public struct mEncryptedFile: Codable {
        public var url: URL
        public var key: JWK
        public var iv: String
        public var hashes: [String: String]
        public var v: String
        
        public init(url: URL, key: JWK, iv: String, hashes: [String : String], v: String) {
            self.url = url
            self.key = key
            self.iv = iv
            self.hashes = hashes
            self.v = v
        }
    }

    // https://matrix.org/docs/spec/client_server/r0.6.0#extensions-to-m-message-msgtypes
    public struct JWK: Codable {
        public var kty: String
        public var key_ops: [String]
        public var alg: String
        public var k: String
        public var ext: Bool
        
        public init(kty: String, key_ops: [String], alg: String, k: String, ext: Bool) {
            self.kty = kty
            self.key_ops = key_ops
            self.alg = alg
            self.k = k
            self.ext = ext
        }
    }

    // https://matrix.org/docs/spec/client_server/r0.6.0#m-audio
    public struct mAudioContent: Matrix.MessageContent {
        public let msgtype: Matrix.MessageType
        public var body: String
        public var info: mAudioInfo
        public var file: mEncryptedFile
        
        public init(msgtype: Matrix.MessageType, body: String, info: mAudioInfo,
                    file: mEncryptedFile) {
            self.msgtype = msgtype
            self.body = body
            self.info = info
            self.file = file
        }
    }

    public struct mAudioInfo: Codable {
        public var duration: UInt
        public var mimetype: String
        public var size: UInt
        
        public init(duration: UInt, mimetype: String, size: UInt) {
            self.duration = duration
            self.mimetype = mimetype
            self.size = size
        }
    }

    // https://matrix.org/docs/spec/client_server/r0.6.0#m-location
    public struct mLocationContent: Matrix.MessageContent {
        public let msgtype: Matrix.MessageType
        public var body: String
        public var geo_uri: String
        public var info: mLocationInfo
        
        public init(msgtype: Matrix.MessageType, body: String, geo_uri: String,
                    info: mLocationInfo) {
            self.msgtype = msgtype
            self.body = body
            self.geo_uri = geo_uri
            self.info = info
        }
    }

    public struct mLocationInfo: Codable {
        public var thumbnail_url: URL?
        public var thumbnail_file: mEncryptedFile?
        public var thumbnail_info: mThumbnailInfo
        
        public init(thumbnail_url: URL? = nil, thumbnail_file: mEncryptedFile? = nil,
                    thumbnail_info: mThumbnailInfo) {
            self.thumbnail_url = thumbnail_url
            self.thumbnail_file = thumbnail_file
            self.thumbnail_info = thumbnail_info
        }
    }

    // https://matrix.org/docs/spec/client_server/r0.6.0#m-video
    public struct mVideoContent: Matrix.MessageContent {
        public let msgtype: Matrix.MessageType
        public var body: String
        public var info: mVideoInfo
        public var file: mEncryptedFile
        
        public init(msgtype: Matrix.MessageType, body: String, info: mVideoInfo,
                    file: mEncryptedFile) {
            self.msgtype = msgtype
            self.body = body
            self.info = info
            self.file = file
        }
    }

    public struct mVideoInfo: Codable {
        public var duration: UInt
        public var h: UInt
        public var w: UInt
        public var mimetype: String
        public var size: UInt
        public var thumbnail_url: URL?
        public var thumbnail_file: mEncryptedFile?
        public var thumbnail_info: mThumbnailInfo
        
        public init(duration: UInt, h: UInt, w: UInt, mimetype: String, size: UInt,
                    thumbnail_url: URL? = nil, thumbnail_file: mEncryptedFile? = nil,
                    thumbnail_info: mThumbnailInfo) {
            self.duration = duration
            self.h = h
            self.w = w
            self.mimetype = mimetype
            self.size = size
            self.thumbnail_url = thumbnail_url
            self.thumbnail_file = thumbnail_file
            self.thumbnail_info = thumbnail_info
        }
    }

} // end extension Matrix
