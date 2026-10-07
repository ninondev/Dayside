// SPDX-License-Identifier: GPL-3.0-only
import Contacts
import Foundation

struct PeopleContactCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum PeopleContactsError: Error { case denied }

protocol PeopleContactsReading: Sendable {
    /// Called only by the user's explicit import action. No startup or background authorization.
    func candidates() async throws -> [PeopleContactCandidate]
}

actor NativePeopleContacts: PeopleContactsReading {
    func candidates() async throws -> [PeopleContactCandidate] {
        try Task.checkCancellation()
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .denied || status == .restricted { throw PeopleContactsError.denied }
        let granted: Bool
        do { granted = try await store.requestAccess(for: .contacts) }
        catch {
            let status = CNContactStore.authorizationStatus(for: .contacts)
            if status == .denied || status == .restricted { throw PeopleContactsError.denied }
            throw error
        }
        try Task.checkCancellation()
        guard granted else { throw PeopleContactsError.denied }
        // Contacts enumeration is synchronous. Keep it off the main actor and propagate cancellation.
        let worker = Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor,
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactOrganizationNameKey as CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.sortOrder = .userDefault
            var values: [PeopleContactCandidate] = []
            try store.enumerateContacts(with: request) { contact, stop in
                if Task.isCancelled { stop.pointee = true; return }
                let personName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                let name = personName.isEmpty ? contact.organizationName : personName
                if !name.isEmpty { values.append(PeopleContactCandidate(id: contact.identifier, name: name)) }
            }
            try Task.checkCancellation()
            return values
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
