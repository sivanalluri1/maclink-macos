import Foundation

struct DeviceIdentityStore {
    private let defaults: UserDefaults
    private let key = "maclink.device.id"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func deviceID() -> UUID {
        if let value = defaults.string(forKey: key), let existing = UUID(uuidString: value) {
            return existing
        }

        let created = UUID()
        defaults.set(created.uuidString.lowercased(), forKey: key)
        return created
    }
}
