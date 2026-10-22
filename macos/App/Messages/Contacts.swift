import Contacts
import Foundation

/// Names for phone numbers and email addresses (spec 002 FR-111, plan D4).
protocol ContactsLookup: Sendable {
    func name(for handle: String) -> String?
}

/// The Mac's Contacts, read once and refreshed every few minutes. Without the Contacts
/// permission it knows no names, and messages show numbers and addresses instead.
final class ContactBook: ContactsLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var byEmail: [String: String] = [:]
    /// Phone numbers by their last 9 digits; a number matches when one ends with the other.
    private var byPhone: [String: [(digits: String, name: String)]] = [:]
    private var loaded: Date?

    static var allowed: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    func name(for handle: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if loaded.map({ Date().timeIntervalSince($0) > 300 }) ?? true { load() }
        if handle.contains("@") { return byEmail[handle.lowercased()] }
        let digits = Self.digits(handle)
        guard digits.count >= 7 else { return nil }
        let candidates = byPhone[String(digits.suffix(9))] ?? []
        let names = Set(candidates.filter { $0.digits.hasSuffix(digits) || digits.hasSuffix($0.digits) }.map(\.name))
        return names.count == 1 ? names.first : nil
    }

    private func load() {
        loaded = Date()
        guard Self.allowed else { return }
        var email: [String: String] = [:]
        var phone: [String: [(String, String)]] = [:]
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
            let name = CNContactFormatter.string(from: c, style: .fullName) ?? c.organizationName
            guard !name.isEmpty else { return }
            for e in c.emailAddresses { email[(e.value as String).lowercased()] = name }
            for p in c.phoneNumbers {
                let d = Self.digits(p.value.stringValue)
                if d.count >= 7 { phone[String(d.suffix(9)), default: []].append((d, name)) }
            }
        }
        byEmail = email
        byPhone = phone
    }

    static func digits(_ s: String) -> String { s.filter(\.isASCII).filter(\.isNumber) }
}
