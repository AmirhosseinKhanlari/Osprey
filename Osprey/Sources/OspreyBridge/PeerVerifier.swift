import Darwin
import Foundation
import Security

/// Decides whether the process on the other end of an accepted socket may talk to Osprey.
public protocol PeerVerifier: Sendable {
    func isAllowed(socket: Int32) -> Bool
}

public struct AllowAllPeerVerifier: PeerVerifier {
    public init() {}
    public func isAllowed(socket: Int32) -> Bool { true }
}

public struct DenyAllPeerVerifier: PeerVerifier {
    public init() {}
    public func isAllowed(socket: Int32) -> Bool { false }
}

/// Accepts only peers signed by our team with one of the given signing identifiers.
/// The peer is identified by its audit token, so a recycled PID can't impersonate it.
public struct CodeSignaturePeerVerifier: PeerVerifier {
    public let requirement: String

    public init(teamID: String, identifiers: [String]) {
        let ids = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (\(ids))"
    }

    public func isAllowed(socket: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let secRequirement else { return false }
        return SecCodeCheckValidity(code, [], secRequirement) == errSecSuccess
    }
}
