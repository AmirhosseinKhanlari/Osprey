import Foundation

public enum MediaError: Error, Equatable, Sendable {
    case toolMissing(String)
    case unsupported
    case drmProtected
    case loginRequired
    case unavailable
    case timedOut
    case extractionFailed(String)
    case muxFailed(String)
    case formatsChanged
    case installFailed(String)
    /// A part of a media download failed; the text is the part's own (already user-facing) message.
    case downloadFailed(String)

    public var userMessage: String {
        switch self {
        case .toolMissing(let name):
            "Couldn't set up the media downloader (\(name) is missing). Check your internet connection and try again."
        case .installFailed(let detail):
            "Couldn't set up the media downloader (\(detail)). Check your internet connection and try again."
        case .unsupported:
            "Osprey can't find video or audio on this page."
        case .drmProtected:
            "This media is protected (DRM) and can't be downloaded."
        case .loginRequired:
            "This page needs you to be signed in. Use Osprey's download button in your browser while signed in."
        case .unavailable:
            "This media is private, was removed, or isn't available in your country."
        case .timedOut:
            "The site took too long to answer. Try again."
        case .extractionFailed(let detail):
            "Couldn't read this page (\(detail))."
        case .muxFailed:
            "Couldn't merge video and audio."
        case .formatsChanged:
            "The site changed this media's formats — start it again"
        case .downloadFailed(let message):
            message
        }
    }
}
