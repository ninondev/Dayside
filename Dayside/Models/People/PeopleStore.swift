// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Observation

@MainActor
@Observable
final class PeopleStore {
    static let storageKey = "meantime.people.v1"
    static let backupPrefix = "meantime.people.corrupt-backup."
    private(set) var people: [PersonProfile] = []
    private(set) var storageNeedsRecovery = false
    private(set) var storageReadOnly = false
    private(set) var rejectedCount = 0
    private(set) var contacts: [PeopleContactCandidate] = []
    private(set) var contactsState: ContactsState = .idle
    enum ContactsState: Equatable { case idle, loading, ready, denied, failed }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let contactsReader: any PeopleContactsReading
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importGeneration = UUID()
    @ObservationIgnored private var originalDamagedValue: Any?

    /// Counts retained live jobs. Cancellation stays counted until the async operation acknowledges it.
    var activeResourceCount: Int { importTask == nil ? 0 : 1 }

    init(defaults: UserDefaults = Store.appDefaults,
         contactsReader: any PeopleContactsReading = NativePeopleContacts()) {
        self.defaults = defaults
        self.contactsReader = contactsReader
        reload()
    }

    private struct DecodeInput: Encodable { let raw: String? }
    private struct DecodeOutput: Decodable {
        let people: [PersonProfile]
        let hadCorruption: Bool
        let readOnly: Bool
        let rejectedCount: Int
    }
    private func reload() {
        let original = defaults.object(forKey: Self.storageKey)
        let result = Self.decode(original)
        people = result.people
        storageNeedsRecovery = result.hadCorruption
        storageReadOnly = result.readOnly
        rejectedCount = result.rejectedCount
        originalDamagedValue = result.hadCorruption ? original : nil
        // Loading never rewrites the user's original value, including partially recovered data.
    }

    /// 冷启动时只读人物快照，不创建通讯录提供者或任务。
    static func savedProfiles(defaults: UserDefaults) -> [PersonProfile] {
        decode(defaults.object(forKey: storageKey)).people
    }

    private static func decode(_ original: Any?) -> DecodeOutput {
        let raw = (original as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? original as? String
        return RustCore.invoke("people.decode", DecodeInput(raw: raw ?? (original == nil ? nil : "invalid")))
    }

    @discardableResult
    func save(_ person: PersonProfile) -> [String] {
        guard !storageReadOnly else { return ["readOnly"] }
        return mutate(action: "save", person: person, id: nil)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard !storageReadOnly, people.contains(where: { $0.id == id }) else { return false }
        return mutate(action: "remove", person: nil, id: id).isEmpty
    }

    private struct MutationInput: Encodable {
        let action: String
        let people: [PersonProfile]
        let person: PersonProfile?
        let id: UUID?
        let timeZoneValid: Bool
    }
    private struct MutationOutput: Decodable {
        let people: [PersonProfile]
        let issues: [String]
        let serialized: String
    }
    private func mutate(action: String, person: PersonProfile?, id: UUID?) -> [String] {
        let zoneValid = person.map { TimeZone(identifier: $0.timeZoneID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil } ?? false
        let result: MutationOutput = RustCore.invoke("people.mutate", MutationInput(
            action: action, people: people, person: person, id: id, timeZoneValid: zoneValid))
        guard result.issues.isEmpty else { return result.issues }
        if let original = originalDamagedValue {
            defaults.set(original, forKey: Self.backupPrefix + UUID().uuidString)
            originalDamagedValue = nil
        }
        defaults.set(Data(result.serialized.utf8), forKey: Self.storageKey)
        people = result.people
        // Keep the recovery notice for this session, so recovered/dropped records stay visible.
        return []
    }

    /// The only entry point that can request Contacts authorization.
    func beginContactsImport() {
        guard importTask == nil else { return }
        contacts.removeAll()
        contactsState = .loading
        let generation = UUID()
        importGeneration = generation
        let reader = contactsReader
        importTask = Task { [weak self] in
            do {
                let candidates = try await reader.candidates()
                try Task.checkCancellation()
                guard let self, self.importGeneration == generation else { return }
                self.contacts = candidates
                self.contactsState = .ready
            } catch is CancellationError {
                if self?.importGeneration == generation { self?.contactsState = .idle }
            } catch PeopleContactsError.denied {
                if self?.importGeneration == generation { self?.contactsState = .denied }
            } catch {
                if self?.importGeneration == generation { self?.contactsState = .failed }
            }
            self?.importTask = nil
        }
    }

    func deactivate() {
        importTask?.cancel()
        importGeneration = UUID()
        contacts.removeAll()
        contactsState = .idle
    }
}
