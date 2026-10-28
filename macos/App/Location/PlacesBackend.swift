import CoreLocation
import Foundation
import MapKit

/// Where the Mac is, and Apple Maps (spec 007 plan D4). The app's backend is Core Location and
/// MapKit; tests use one in memory and make no network calls.
struct Coordinate: Sendable, Equatable {
    var latitude: Double
    var longitude: Double

    var text: String { String(format: "%.5f,%.5f", latitude, longitude) }

    /// `37.33,-122.03`, or nil when the text isn't coordinates.
    static func parse(_ s: String) -> Coordinate? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
            (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }

    func distance(to o: Coordinate) -> Double {
        CLLocation(latitude: latitude, longitude: longitude).distance(
            from: CLLocation(latitude: o.latitude, longitude: o.longitude))
    }
}

struct Fix: Sendable, Equatable {
    var coordinate: Coordinate
    /// Metres.
    var accuracy: Double
    var at: Date
}

struct Place: Sendable, Equatable {
    var name: String
    var address: String?
    var coordinate: Coordinate
    var phone: String?
    var url: String?
    var category: String?
}

struct Route: Sendable, Equatable {
    /// Metres; nil for public transport (only the time is known).
    var distance: Double?
    var seconds: Double
    var name: String?
    var steps: [String] = []
    var departure: Date?
    var arrival: Date?
}

/// `unknown`: Core Location hasn't said yet. A new location manager reports "not determined"
/// until its first authorization callback, so nothing is decided on that (2026-10-27: the setup
/// window opened over a finished setup).
enum LocationAccess: Sendable, Equatable { case allowed, notAsked, denied, servicesOff, unknown }

enum PlacesFailure: Error, Equatable {
    case location(LocationAccess)
    case noFix
    case nothingFound(String)
    case noRoute(String)
    case failed(String)
}

protocol PlacesBackend: Sendable {
    func locationAccess() -> LocationAccess
    func currentFix() async throws -> Fix
    func reverse(_ c: Coordinate) async throws -> Place?
    func geocode(_ address: String) async throws -> [Place]
    func search(_ query: String, near: Coordinate?, limit: Int) async throws -> [Place]
    func route(from: Coordinate, to: Coordinate, mode: String, departAt: Date?, arriveBy: Date?) async throws -> Route
}

/// Core Location and MapKit.
final class AppleMapsBackend: PlacesBackend, @unchecked Sendable {
    static let shared = AppleMapsBackend()

    /// What Core Location last told the app's location manager (`LocationFixer`), never a fresh
    /// manager's first guess.
    func locationAccess() -> LocationAccess { LocationFixer.known.value }

    static func access(_ status: CLAuthorizationStatus, servicesOn: Bool) -> LocationAccess {
        guard servicesOn else { return .servicesOff }
        switch status {
        case .authorizedAlways, .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    func currentFix() async throws -> Fix {
        let access = locationAccess()
        guard access == .allowed else { throw PlacesFailure.location(access) }
        guard let fix = await LocationFixer.shared.fix() else { throw PlacesFailure.noFix }
        return fix
    }

    private static func place(_ item: MKMapItem) -> Place {
        Place(
            name: item.name ?? item.address?.shortAddress ?? "(no name)", address: item.address?.fullAddress,
            coordinate: Coordinate(
                latitude: item.location.coordinate.latitude, longitude: item.location.coordinate.longitude),
            phone: item.phoneNumber, url: item.url?.absoluteString,
            category: item.pointOfInterestCategory.map { Self.category($0) })
    }

    /// `MKPOICategoryCafe` → `cafe`.
    private static func category(_ c: MKPointOfInterestCategory) -> String {
        c.rawValue.replacingOccurrences(of: "MKPOICategory", with: "").lowercased()
    }

    private static func location(_ c: Coordinate) -> CLLocation {
        CLLocation(latitude: c.latitude, longitude: c.longitude)
    }

    func reverse(_ c: Coordinate) async throws -> Place? {
        guard let request = MKReverseGeocodingRequest(location: Self.location(c)) else { return nil }
        do { return try await request.mapItems.first.map(Self.place) } catch {
            throw PlacesFailure.failed(error.localizedDescription)
        }
    }

    func geocode(_ address: String) async throws -> [Place] {
        guard let request = MKGeocodingRequest(addressString: address) else {
            throw PlacesFailure.nothingFound(address)
        }
        do { return try await request.mapItems.map(Self.place) } catch {
            throw PlacesFailure.nothingFound(address)
        }
    }

    func search(_ query: String, near: Coordinate?, limit: Int) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        do { return try await MKLocalSearch(request: request).start().mapItems.prefix(limit).map(Self.place) } catch {
            throw PlacesFailure.nothingFound(query)
        }
    }

    func route(from: Coordinate, to: Coordinate, mode: String, departAt: Date?, arriveBy: Date?) async throws -> Route {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: Self.location(from), address: nil)
        request.destination = MKMapItem(location: Self.location(to), address: nil)
        request.transportType = mode == "walking" ? .walking : mode == "transit" ? .transit : .automobile
        if let departAt { request.departureDate = departAt }
        if let arriveBy { request.arrivalDate = arriveBy }
        let directions = MKDirections(request: request)
        do {
            if mode == "transit" {
                let eta = try await directions.calculateETA()
                return Route(
                    distance: nil, seconds: eta.expectedTravelTime, departure: eta.expectedDepartureDate,
                    arrival: eta.expectedArrivalDate)
            }
            guard let r = try await directions.calculate().routes.first else { throw PlacesFailure.noRoute(mode) }
            return Route(
                distance: r.distance, seconds: r.expectedTravelTime, name: r.name.nilIfEmpty,
                steps: r.steps.map(\.instructions).filter { !$0.isEmpty })
        } catch let f as PlacesFailure {
            throw f
        } catch {
            throw PlacesFailure.noRoute(error.localizedDescription)
        }
    }
}

/// One location fix at a time, reused for five minutes (research.md "Location fix"). Core
/// Location calls its delegate on the thread that made the manager, so it lives on the main actor.
@MainActor
final class LocationFixer: NSObject, CLLocationManagerDelegate {
    static let shared = LocationFixer()

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Fix?, Never>] = []
    private var last: Fix?

    /// The permission as Core Location last reported it to this manager; `unknown` until its first
    /// callback, which comes right after the manager is made. Readable from any thread.
    nonisolated static let known = Locked(LocationAccess.unknown)
    /// Called on the main actor whenever the permission is reported.
    var onAccessChange: (@MainActor (LocationAccess) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let access = AppleMapsBackend.access(
            manager.authorizationStatus, servicesOn: CLLocationManager.locationServicesEnabled())
        Self.known.mutate { $0 = access }
        Task { @MainActor in self.onAccessChange?(access) }
    }

    /// Asks macOS once (setup only, FR-742).
    func requestAccess() { manager.requestWhenInUseAuthorization() }

    func fix(timeout: Duration = .seconds(10)) async -> Fix? {
        if let last, Date().timeIntervalSince(last.at) < 300 { return last }
        return await withCheckedContinuation { c in
            waiting.append(c)
            guard waiting.count == 1 else { return }  // a request is already out; wait for it
            generation += 1
            let mine = generation
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if self.generation == mine { self.finish(nil) }
            }
        }
    }

    /// Which request is out, so an old request's time limit doesn't end a newer one.
    private var generation = 0

    private func finish(_ fix: Fix?) {
        if let fix { last = fix }
        let all = waiting
        waiting = []
        for c in all { c.resume(returning: fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let fix = Fix(
            coordinate: Coordinate(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude),
            accuracy: l.horizontalAccuracy, at: l.timestamp)
        Task { @MainActor in self.finish(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
