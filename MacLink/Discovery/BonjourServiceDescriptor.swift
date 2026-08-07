import Foundation

struct BonjourServiceDescriptor: Equatable, Sendable {
    static let serviceType = "_maclink._tcp"
    static let protocolVersion = "1"

    let deviceID: UUID
    let displayName: String

    var serviceName: String {
        "MacLink – \(displayName)"
    }

    var txtRecord: Data {
        NetService.data(fromTXTRecord: [
            "pv": Data(Self.protocolVersion.utf8),
            "id": Data(deviceID.uuidString.lowercased().utf8),
            "name": Data(displayName.prefix(63).utf8),
            "pairing": Data("1".utf8),
        ])
    }

    static func decodeTXTRecord(_ data: Data) -> [String: String] {
        NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { result, entry in
            guard let value = String(data: entry.value, encoding: .utf8) else { return }
            result[entry.key] = value
        }
    }
}

