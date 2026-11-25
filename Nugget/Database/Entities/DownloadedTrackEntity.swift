//
//  DownloadedTrackEntity.swift
//  Nugget
//
//  Created on 19/07/2026.
//

import Foundation
import GRDB

struct DownloadedTrackEntity: Codable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var title: String
    var artist: String
    var duration: Int
    var thumbnailUrl: String?
    var localPath: String
    var downloadedAt: Date
    var itag: Int?
    var codec: String?
    var bitrate: Int?

    static let databaseTableName = "downloaded_track"

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case duration
        case thumbnailUrl = "thumbnail_url"
        case localPath = "local_path"
        case downloadedAt = "downloaded_at"
        case itag
        case codec
        case bitrate
    }

    var audioBadgeText: String? {
        AudioQualityBadgeHelper.badgeText(itag: itag, codec: codec, bitrate: bitrate)
    }

    var is256AAC: Bool {
        AudioQualityBadgeHelper.is256AAC(itag: itag, codec: codec, bitrate: bitrate)
    }
}
