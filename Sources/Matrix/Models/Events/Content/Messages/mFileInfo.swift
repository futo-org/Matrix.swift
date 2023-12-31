//
//  mFileInfo.swift
//
//
//  Created by Charles Wright on 12/12/23.
//

import Foundation

extension Matrix {
    public struct mFileInfo: Codable {
        public var mimetype: String
        public var size: UInt
        public var thumbnail_file: mEncryptedFile?
        public var thumbnail_info: mThumbnailInfo
        public var thumbnail_url: MXC?
        public var blurhash: String?
        public var thumbhash: String?
        
        public init(mimetype: String,
                    size: UInt,
                    thumbnail_file: mEncryptedFile?,
                    thumbnail_url: MXC? = nil,
                    thumbnail_info: mThumbnailInfo,
                    blurhash: String? = nil,
                    thumbhash: String? = nil
        ) {
            self.mimetype = mimetype
            self.size = size
            self.thumbnail_info = thumbnail_info
            self.thumbnail_file = thumbnail_file
            self.thumbnail_url = thumbnail_url
            self.blurhash = blurhash
            self.thumbhash = thumbhash
        }
        
        // Custom Decodable implementation -- Ignore invalid elements if they're optionals
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            self.mimetype = try container.decode(String.self, forKey: .mimetype)
            self.size = try container.decode(UInt.self, forKey: .size)
            self.thumbnail_file = try? container.decodeIfPresent(mEncryptedFile.self, forKey: .thumbnail_file)
            self.thumbnail_info = try container.decode(mThumbnailInfo.self, forKey: .thumbnail_info)
            self.thumbnail_url = try? container.decodeIfPresent(MXC.self, forKey: .thumbnail_url)
            self.blurhash = try? container.decodeIfPresent(String.self, forKey: .blurhash)
            self.thumbhash = try? container.decodeIfPresent(String.self, forKey: .thumbhash)
        }
    }
}
