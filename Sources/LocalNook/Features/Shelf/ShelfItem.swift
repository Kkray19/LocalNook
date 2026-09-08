//
//  ShelfItem.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// One thing sitting on the shelf.
///
/// Files dropped from Finder are referenced **in place** by default — LocalNook
/// does not copy your files around behind your back. Only content that has no
/// file of its own (dragged text, a snippet of a web page) is written into
/// LocalNook's own storage.
struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case file
        case folder
        case image
        case url
        case text
    }

    let id: UUID
    var kind: Kind
    var name: String
    /// Where the item actually lives. For `.file`/`.folder`/`.image` this is the
    /// user's own path; for `.text` it is a file inside LocalNook's storage.
    var path: String?
    /// Payload for `.url` and `.text`.
    var payload: String?
    var addedAt: Date
    /// True when LocalNook created the file and may delete it on removal.
    var isOwned: Bool

    var url: URL? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Whether the referenced file still exists — a dropped file can be moved
    /// or deleted after it lands on the shelf.
    var stillExists: Bool {
        guard let path else { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    var symbol: String {
        switch kind {
        case .file: "doc"
        case .folder: "folder"
        case .image: "photo"
        case .url: "link"
        case .text: "text.alignleft"
        }
    }

    var subtitle: String {
        switch kind {
        case .url: payload ?? ""
        case .text: (payload ?? "").prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            if let url, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            } else {
                url?.deletingLastPathComponent().lastPathComponent ?? ""
            }
        }
    }

    static func fromFile(_ url: URL) -> ShelfItem {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let type = UTType(filenameExtension: url.pathExtension)
        let kind: Kind = if isDirectory.boolValue {
            .folder
        } else if type?.conforms(to: .image) == true {
            .image
        } else {
            .file
        }
        return ShelfItem(
            id: UUID(), kind: kind, name: url.lastPathComponent, path: url.path,
            payload: nil, addedAt: Date(), isOwned: false
        )
    }

    static func fromURL(_ url: URL) -> ShelfItem {
        ShelfItem(
            id: UUID(), kind: .url, name: url.host ?? url.absoluteString,
            path: nil, payload: url.absoluteString, addedAt: Date(), isOwned: false
        )
    }
}
