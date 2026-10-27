import Foundation

/// Where the Mac is, places, and directions (spec 007 US4), through Core Location and MapKit
/// (plan D4). Off or On; nothing changes anything, so both tools are read-only.
enum LocationCapability {
    static func make() -> Capability {
        Capability(
            id: CapabilityRegistry.location, title: "Location & Maps",
            summary: "See where this Mac is, find places, and get directions and travel times",
            readTools: tools(backend: AppleMapsBackend.shared, zone: { .current }), writeTools: [],
            levels: [.off, .readWrite], onTitle: "On")
    }

    static func explain(_ access: LocationAccess) -> String {
        switch access {
        case .servicesOff:
            "Location Services are turned off on this Mac, so it can't tell where it is. The Mac's owner can turn them on in System Settings → Privacy & Security → Location Services."
        case .notAsked, .denied:
            "Latchkey isn't allowed to see where this Mac is. The Mac's owner can allow Location in Latchkey's Settings → Permissions."
        case .allowed: ""
        }
    }

    static let modes = ["driving", "walking", "transit"]
    static let maxPlaces = 25

    static func tools(backend: any PlacesBackend, zone: @escaping CalendarCapability.Zone) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "location_read", title: "Where Is the Mac",
                    description:
                        "Gives the Mac's current location: coordinates, how accurate they are, when they were measured, and the street address. The Mac measures it from nearby Wi-Fi.",
                    readOnly: true, deadlineMS: 15_000),
                handler: { _ in await run { try await read(backend) } }),
            ToolEntry(
                tool: .make(
                    "maps_find", title: "Search Maps",
                    description: """
                        Apple Maps from the Mac. Give one of: query (places by name or kind, like "coffee" or \
                        "Sutter Health", near near: an address, lat,lon, or here for the Mac; default the Mac), \
                        to (directions and travel time from from, default here, by mode: driving (default), \
                        walking, or transit (time only); optionally depart_at or arrive_by), or address (its \
                        coordinates; or lat,lon for its address). Dates: \(CalendarDates.accepted).
                        """,
                    input: [
                        "query": .stringParam("What to look for"),
                        "near": .stringParam("Where to look: an address, lat,lon, or here"),
                        "to": .stringParam("Where to go: an address, lat,lon, or here"),
                        "from": .stringParam("Where from (default here)"),
                        "mode": .enumParam(modes, "How to travel (default driving)"),
                        "depart_at": .stringParam("Leave at this time"),
                        "arrive_by": .stringParam("Arrive by this time"),
                        "address": .stringParam("An address to find, or lat,lon to name"),
                        "limit": .integerParam("At most this many places (default 10, up to 25)"),
                    ], readOnly: true, openWorld: true, deadlineMS: 20_000),
                handler: { args in await run { try await find(args, backend, zone()) } }),
        ]
    }

    static func read(_ backend: any PlacesBackend) async throws -> ToolResult {
        let fix = try await backend.currentFix()
        var lines = [
            "The Mac is at \(fix.coordinate.text) (within about \(Int(fix.accuracy.rounded())) m), measured \(CalendarDates.format(fix.at))."
        ]
        if let place = try? await backend.reverse(fix.coordinate), let address = place.address {
            lines.append("Address: \(address)")
        }
        lines.append(CalendarDates.zoneLine())
        return .text(lines.joined(separator: "\n"))
    }

    /// An address, `lat,lon`, or `here` as a point; the Mac's location needs Location allowed.
    static func resolve(_ s: String, _ backend: any PlacesBackend) async throws -> (Coordinate, String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.lowercased() == "here" { return ((try await backend.currentFix()).coordinate, "the Mac") }
        if let c = Coordinate.parse(t) { return (c, t) }
        guard let p = try await backend.geocode(t).first else { throw PlacesFailure.nothingFound(t) }
        return (p.coordinate, p.address ?? p.name)
    }

    static func find(_ args: JSONValue, _ backend: any PlacesBackend, _ zone: TimeZone) async throws -> ToolResult {
        let given = ["query", "to", "address"].filter { args.hasAny($0) }
        guard given.count == 1, let what = given.first else {
            throw ArgumentError(message: "Give exactly one of query (places), to (directions), or address.")
        }
        switch what {
        case "query":
            let query = args["query"]?.stringValue ?? ""
            var center: Coordinate?
            var around = "anywhere"
            if let near = args["near"]?.stringValue, !near.isEmpty {
                (center, around) = try await resolve(near, backend)
            } else if backend.locationAccess() == .allowed, let fix = try? await backend.currentFix() {
                (center, around) = (fix.coordinate, "the Mac")
            }
            let limit = min(try args.integer("limit", in: 1...Int.max) ?? 10, maxPlaces)
            let places = try await backend.search(query, near: center, limit: limit)
            guard !places.isEmpty else { throw PlacesFailure.nothingFound(query) }
            var lines = ["Places for “\(query)” near \(around):"]
            lines += places.map { p in
                var s = "- \(p.name)"
                if let c = p.category { s += " (\(c))" }
                if let a = p.address { s += ", \(a)" }
                if let center { s += ", \(distance(center.distance(to: p.coordinate)))" }
                if let ph = p.phone { s += ", \(ph)" }
                if let u = p.url { s += ", \(u)" }
                return s + " [\(p.coordinate.text)]"
            }
            return .text(lines.joined(separator: "\n"))
        case "to":
            let mode = args["mode"]?.stringValue ?? "driving"
            guard modes.contains(mode) else { return .unknown("mode", mode, allowed: modes) }
            let depart = try CalendarDates.argument(args, "depart_at", zone: zone)?.date
            let arrive = try CalendarDates.argument(args, "arrive_by", zone: zone)?.date
            if depart != nil && arrive != nil { throw ArgumentError(message: "Give depart_at or arrive_by, not both.") }
            let (from, fromName) = try await resolve(args["from"]?.stringValue ?? "here", backend)
            let (to, toName) = try await resolve(args["to"]?.stringValue ?? "", backend)
            let r = try await backend.route(from: from, to: to, mode: mode, departAt: depart, arriveBy: arrive)
            var lines = [
                "\(mode.capitalized) from \(fromName) to \(toName): \(CalendarCapability.duration(r.seconds))"
                    + (r.distance.map { ", \(distance($0))" } ?? "") + (r.name.map { " via \($0)" } ?? "") + "."
            ]
            if let d = r.departure, let a = r.arrival {
                lines.append(
                    "Leave \(CalendarDates.format(d, zone: zone)), arrive \(CalendarDates.format(a, zone: zone)).")
                lines.append(CalendarDates.zoneLine(zone, at: d))
            }
            if mode == "transit" {
                lines.append("Apple Maps gives apps only the time for public transport, not the route.")
            }
            if !r.steps.isEmpty { lines += ["Steps:"] + r.steps.enumerated().map { "\($0.offset + 1). \($0.element)" } }
            return .text(lines.joined(separator: "\n"))
        default:
            let address = args["address"]?.stringValue ?? ""
            if let c = Coordinate.parse(address) {
                guard let p = try await backend.reverse(c), let a = p.address else {
                    throw PlacesFailure.nothingFound(address)
                }
                return .text("\(c.text) is \(a).")
            }
            let found = try await backend.geocode(address)
            guard !found.isEmpty else { throw PlacesFailure.nothingFound(address) }
            return .text(
                found.prefix(5).map { "- \($0.address ?? $0.name): \($0.coordinate.text)" }.joined(separator: "\n"))
        }
    }

    static func distance(_ metres: Double) -> String {
        let km = metres / 1000
        let miles = metres / 1609.344
        return metres < 1000
            ? "\(Int(metres.rounded())) m (\(String(format: "%.1f", miles)) mi)"
            : String(format: "%.1f km (%.1f mi)", km, miles)
    }

    static func run(_ body: () async throws -> ToolResult) async -> ToolResult {
        do { return try await body() } catch let e as ArgumentError {
            return .text(e.message, isError: true)
        } catch let f as PlacesFailure {
            let text: String =
                switch f {
                case .location(let access): explain(access)
                case .noFix:
                    "The Mac couldn't tell where it is just now (no Wi-Fi networks nearby, or no answer within 10 seconds)."
                case .nothingFound(let what): "Apple Maps found nothing for “\(what)”."
                case .noRoute(let why): "Apple Maps has no route for that: \(why)"
                case .failed(let why): "Apple Maps didn't answer: \(why)"
                }
            return .text(text, isError: true)
        } catch {
            return .text("Latchkey couldn't do that: \(error.localizedDescription)", isError: true)
        }
    }
}
