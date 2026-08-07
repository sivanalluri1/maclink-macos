import Foundation

struct PhonePresence: Codable, Equatable, Sendable {
    static let messageKind = "device_presence"
    static let protocolVersion = 1
    static let maximumDeviceNameLength = 80
    static let maximumAppVersionLength = 32

    let deviceID: UUID
    let deviceName: String
    let appVersion: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case deviceID = "deviceId"
        case deviceName
        case platform
        case appVersion
    }

    init(deviceID: UUID, deviceName: String, appVersion: String) throws {
        let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              trimmedName.count <= Self.maximumDeviceNameLength,
              !appVersion.isEmpty,
              appVersion.count <= Self.maximumAppVersionLength else {
            throw PhonePresenceError.invalidPayload
        }

        self.deviceID = deviceID
        self.deviceName = trimmedName
        self.appVersion = appVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .kind) == Self.messageKind,
              try container.decode(Int.self, forKey: .version) == Self.protocolVersion,
              try container.decode(String.self, forKey: .platform) == "android" else {
            throw PhonePresenceError.invalidPayload
        }

        try self.init(
            deviceID: container.decode(UUID.self, forKey: .deviceID),
            deviceName: container.decode(String.self, forKey: .deviceName),
            appVersion: container.decode(String.self, forKey: .appVersion)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.messageKind, forKey: .kind)
        try container.encode(Self.protocolVersion, forKey: .version)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode("android", forKey: .platform)
        try container.encode(appVersion, forKey: .appVersion)
    }
}

enum PhonePresenceError: Error {
    case invalidPayload
}

struct PresenceAcknowledgement: Encodable, Sendable {
    let kind = "presence_ack"
    let version = 1
    let macDeviceID: UUID
    let macName: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case macDeviceID = "macDeviceId"
        case macName
    }
}
