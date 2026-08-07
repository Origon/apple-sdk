import Foundation
import UIKit
import OrigonSDK

/// One pending-upload tile in the chat composer.
///
/// `id` is a local UUID assigned at pick time. It serves two purposes:
/// (1) the SwiftUI `Identifiable` key for `ForEach`; and (2) the
/// `uploadId` we pass to `client.uploadAttachment(...)` so that
/// `client.deleteAttachment(attachmentId: id)` can cancel the upload
/// in-flight (the SDK's dual-purpose deleteAttachment matches the
/// id against its in-flight upload table first, then falls through
/// to a server-side DELETE).
struct PendingAttachment: Identifiable, Equatable {
    let id: String
    let fileName: String
    let contentType: String
    let previewImage: UIImage?
    var status: Status
    var progress: Double
    var attachment: Attachment?
    var errorText: String?

    enum Status: Equatable {
        case uploading
        case completed
        case error
    }

    var isImage: Bool { contentType.hasPrefix("image/") }

    var fileExtension: String {
        (fileName as NSString).pathExtension.uppercased()
    }

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id
            && lhs.status == rhs.status
            && lhs.progress == rhs.progress
            && lhs.attachment == rhs.attachment
            && lhs.errorText == rhs.errorText
    }
}
