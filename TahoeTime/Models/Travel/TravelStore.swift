// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

@MainActor
@Observable
final class TravelStore {
    static let storageKey = "meantime.travel.v1"
    static let backupPrefix = "meantime.travel.corrupt-backup."
    private(set) var trips: [TravelTrip] = []
    private(set) var autoSwitchEnabled = false
    private(set) var storageNeedsRecovery = false
    private(set) var storageReadOnly = false
    private(set) var rejectedCount = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var originalDamagedValue: Any?

    // This lens owns no tasks, observers or timers; it receives existing system events from the hub.
    var activeResourceCount: Int { 0 }
    func deactivate() {}

    init(defaults: UserDefaults = Store.appDefaults) {
        self.defaults = defaults
        struct Input: Encodable { let raw: String? }
        struct Output: Decodable {
            let trips: [TravelTrip]
            let autoSwitchEnabled: Bool
            let hadCorruption: Bool
            let readOnly: Bool
            let rejectedCount: Int
        }
        let original = defaults.object(forKey: Self.storageKey)
        let raw = (original as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? original as? String
        let result: Output = RustCore.invoke("travel.decode", Input(raw: raw ?? (original == nil ? nil : "invalid")))
        trips = result.trips
        autoSwitchEnabled = result.autoSwitchEnabled
        storageNeedsRecovery = result.hadCorruption
        storageReadOnly = result.readOnly
        rejectedCount = result.rejectedCount
        originalDamagedValue = result.hadCorruption ? original : nil
    }

    @discardableResult
    func save(_ trip: TravelTrip) -> [String] {
        guard !storageReadOnly else { return ["readOnly"] }
        return mutate(action: "save", trip: trip)
    }
    @discardableResult
    func remove(id: UUID) -> Bool {
        guard !storageReadOnly, trips.contains(where: { $0.id == id }) else { return false }
        return mutate(action: "remove", id: id).isEmpty
    }
    @discardableResult
    func setAutoSwitchEnabled(_ enabled: Bool) -> Bool {
        guard !storageReadOnly else { return false }
        return mutate(action: "setAutoSwitch", enabled: enabled).isEmpty
    }

    private struct MutationInput: Encodable {
        let action: String
        let trips: [TravelTrip]
        let autoSwitchEnabled: Bool
        let trip: TravelTrip?
        let id: UUID?
        let enabled: Bool?
        let originTimeZoneValid: Bool
        let destinationTimeZoneValid: Bool
    }
    private struct MutationOutput: Decodable {
        let trips: [TravelTrip]
        let autoSwitchEnabled: Bool
        let serialized: String
        let issues: [String]
    }
    private func mutate(action: String, trip: TravelTrip? = nil, id: UUID? = nil, enabled: Bool? = nil) -> [String] {
        let result: MutationOutput = RustCore.invoke("travel.mutate", MutationInput(
            action: action, trips: trips, autoSwitchEnabled: autoSwitchEnabled, trip: trip, id: id, enabled: enabled,
            originTimeZoneValid: trip.map { TimeZone(identifier: $0.originTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil } ?? false,
            destinationTimeZoneValid: trip.map { TimeZone(identifier: $0.destinationTimeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil } ?? false))
        guard result.issues.isEmpty else { return result.issues }
        if let originalDamagedValue {
            defaults.set(originalDamagedValue, forKey: Self.backupPrefix + UUID().uuidString)
            self.originalDamagedValue = nil
        }
        defaults.set(Data(result.serialized.utf8), forKey: Self.storageKey)
        trips = result.trips
        autoSwitchEnabled = result.autoSwitchEnabled
        return []
    }

    /// Called by the hub's existing timezone-change handler. Matching offset alone never selects a city.
    func preferredMainClockID(systemTimeZoneID: String, places: [TimeZoneEntry]) -> UUID? {
        struct Zone: Encodable { let id: UUID; let timeZoneID: String }
        struct Input: Encodable { let enabled: Bool; let systemTimeZoneID: String; let zones: [Zone] }
        return RustCore.invoke("travel.primary_change", Input(enabled: autoSwitchEnabled,
            systemTimeZoneID: systemTimeZoneID, zones: places.map { Zone(id: $0.id, timeZoneID: $0.timezoneID) }))
    }
}
