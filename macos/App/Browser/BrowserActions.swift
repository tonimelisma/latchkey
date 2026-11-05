import Foundation

/// The browser actions added on 2026-11-04 (spec 005 FR-433 to FR-438, Toni: "all the safari
/// stuff"): keys, hover, scrolling, choosing from lists, attaching files, and saving files. Each
/// runs in the page Claude works in, through the same tab checks as a click, so it works in a
/// background tab, and in Latchkey's own browser while the Mac is locked.
extension BrowserCapability {
    static let directions = ["down", "up", "left", "right", "top", "bottom"]

    /// Latchkey's own browser while the Mac is locked, else Safari.
    static func either<T>(
        _ l: LockedBrowser?, _ own: (LockedBrowser) async throws -> T, _ safari: () async throws -> T
    ) async throws -> T {
        if let l { return try await own(l) }
        return try await safari()
    }

    static func listParam(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"), "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    /// A list argument given as a list of texts, or as one text.
    static func texts(_ args: JSONValue, _ key: String) throws -> [String]? {
        switch args[key] {
        case nil, .null?: return nil
        case .string(let s)?: return s.isEmpty ? nil : [s]
        case .array(let items)?:
            let out = items.compactMap(\.stringValue)
            guard out.count == items.count else { throw ArgumentError(message: "\(key) is a list of texts.") }
            return out.isEmpty ? nil : out
        default: throw ArgumentError(message: "\(key) is a list of texts.")
        }
    }

    /// Keys as Claude writes them: "Enter", "Tab Tab Enter", "cmd+a", or a list of them.
    static func keyList(_ args: JSONValue) throws -> [PageScripts.Key] {
        guard let given = try texts(args, "keys") else {
            throw ArgumentError(message: "Give keys, like \"Enter\", \"Tab\", \"Escape\", \"ArrowDown\", or \"cmd+a\".")
        }
        let names = given.count == 1 && given[0].count > 1 ? given[0].split(separator: " ").map(String.init) : given
        guard names.count <= 50 else { throw ArgumentError(message: "At most 50 keys at a time.") }
        return try names.map {
            do { return try PageScripts.Key($0) } catch {
                throw ArgumentError(
                    message:
                        "Latchkey doesn't know the key \"\($0)\". Use names like Enter, Escape, Tab, Backspace, Delete, Space, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, Home, End, PageUp, PageDown, a single character, and cmd+, ctrl+, alt+, shift+ before them."
                )
            }
        }
    }

    /// The answer after one of these actions: what it did, then the page.
    static func acted(
        _ said: String, _ p: PageScripts.Page, _ l: LockedBrowser?, _ browser: SafariBrowser, activity: String
    ) async -> ToolResult {
        let working = l == nil ? await browser.working() : nil
        var r = await told(
            .text(said + "\n\n" + (working.map { named($0) + "\n" } ?? "") + PageScripts.answer(p)), l, browser)
        r.activity = activity
        return r
    }

    static func actionOperations(browser: SafariBrowser, locked: @escaping LockedRoute = noLocked) -> [ToolEntry] {
        [
            ToolEntry(
                tool: .make(
                    "browser_key", title: "Press Keys",
                    description: "Presses keys in the page, in the field ref names or the one with the focus.",
                    input: [
                        "keys": listParam("Keys, like Enter, Tab, Escape, ArrowDown, cmd+a"),
                        "ref": .stringParam("A field"),
                    ],
                    required: ["keys"], readOnly: false, destructive: true, openWorld: true, deadlineMS: 30_000),
                handler: { args in
                    await run {
                        let keys = try keyList(args)
                        let ref = args["ref"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                        let a = try answer(args)
                        let l = await route(browser, locked)
                        let done = try await either(
                            l, { try await $0.press(keys, ref: ref, answer: a) },
                            { try await browser.press(keys, ref: ref, answer: a) })
                        let did = (try? JSONDecoder().decode([String].self, from: Data(done.detail.utf8))) ?? []
                        return await acted(
                            "Pressed (keys a script sends; a site that only takes a real keyboard won't notice them):\n"
                                + did.map { "- " + $0 }.joined(separator: "\n"), done.page, l, browser,
                            activity: "Pressed \(keys.map(\.key).joined(separator: " ")) on \(host(done.page.url))")
                    }
                }),
            ToolEntry(
                tool: .make(
                    "browser_hover", title: "Hover",
                    description: "Moves a pretend pointer onto an element, for menus that open on hover.",
                    input: ["ref": .stringParam("The element")], required: ["ref"], readOnly: false, destructive: true,
                    openWorld: true, deadlineMS: 30_000),
                handler: { args in
                    await run {
                        guard let ref = args["ref"]?.stringValue, !ref.isEmpty else {
                            throw Failure.failed("Give the element's reference.")
                        }
                        let l = await route(browser, locked)
                        let done = try await either(l, { try await $0.hover(ref) }, { try await browser.hover(ref) })
                        let shown = Int(done.detail) ?? 0
                        return await acted(
                            shown > 0
                                ? "Hovered over \(ref); \(shown) more things on the page show now."
                                : "Hovered over \(ref); nothing new shows (a menu styled to open only under a real pointer doesn't open from a script; clicking it often does).",
                            done.page, l, browser, activity: "Hovered over \(ref) on \(host(done.page.url))")
                    }
                }),
            ToolEntry(
                tool: .make(
                    "browser_scroll", title: "Scroll",
                    description: "Scrolls the page, or the part of it ref names.",
                    input: [
                        "direction": .enumParam(directions, "Which way"), "amount": .integerParam("Pixels"),
                        "ref": .stringParam("Scroll inside this element"),
                    ], readOnly: false, destructive: true, openWorld: true, deadlineMS: 30_000),
                handler: { args in
                    await run {
                        let direction = args["direction"]?.stringValue ?? "down"
                        guard directions.contains(direction) else {
                            throw ArgumentError(message: "direction is one of: \(directions.joined(separator: ", ")).")
                        }
                        let amount = try args.integer("amount", in: 1...1_000_000)
                        let ref = args["ref"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                        let l = await route(browser, locked)
                        let done =
                            try await either(
                                l, { try await $0.scroll(ref, direction: direction, amount: amount) },
                                { try await browser.scroll(ref, direction: direction, amount: amount) })
                        let at = try? JSONDecoder().decode(
                            PageScripts.ScrollPosition.self, from: Data(done.detail.utf8))
                        return await acted(
                            "Scrolled \(direction). " + (at?.said ?? ""), done.page, l, browser,
                            activity: "Scrolled on \(host(done.page.url))")
                    }
                }),
            ToolEntry(
                tool: .make(
                    "browser_select", title: "Choose from a List",
                    description:
                        "Chooses options in a list by their text or value (several in a list that takes several).",
                    input: ["ref": .stringParam("The list"), "options": listParam("The options' texts")],
                    required: ["ref", "options"], readOnly: false, destructive: true, openWorld: true,
                    deadlineMS: 30_000),
                handler: { args in
                    await run {
                        guard let ref = args["ref"]?.stringValue, !ref.isEmpty,
                            let options = try texts(args, "options") ?? texts(args, "text")
                        else { throw Failure.failed("Give the list's reference and the options to choose.") }
                        let a = try answer(args)
                        let l = await route(browser, locked)
                        let done = try await either(
                            l, { try await $0.choose(ref, options: options, answer: a) },
                            { try await browser.choose(ref, options: options, answer: a) })
                        let chosen = (try? JSONDecoder().decode([String].self, from: Data(done.detail.utf8))) ?? options
                        return await acted(
                            "Chose (website text): " + chosen.map { "\"\($0)\"" }.joined(separator: ", "), done.page, l,
                            browser, activity: "Chose from \(ref) on \(host(done.page.url))")
                    }
                }),
            ToolEntry(
                tool: .make(
                    "browser_upload", title: "Attach Files",
                    description:
                        "Attaches files from the Mac to a file field of the page, or drops them on a place that takes dropped files.",
                    input: [
                        "ref": .stringParam("The file field or drop place"), "paths": listParam("The files' paths"),
                    ],
                    required: ["ref", "paths"], readOnly: false, destructive: true, openWorld: true, deadlineMS: 30_000),
                handler: { args in
                    await run {
                        guard let ref = args["ref"]?.stringValue, !ref.isEmpty,
                            let paths = try texts(args, "paths") ?? texts(args, "path")
                        else { throw Failure.failed("Give the field's reference and the files' paths.") }
                        let files = try BrowserDownloads.attachments(paths)
                        let a = try answer(args)
                        let l = await route(browser, locked)
                        let done = try await either(
                            l, { try await $0.attach(ref, files: files, answer: a) },
                            { try await browser.attach(ref, files: files, answer: a) })
                        let how = done.detail.contains("dropped") ? "Dropped" : "Attached"
                        let list = files.map { "\($0.name) (\(BrowserDownloads.size($0.data.count)))" }
                        return await acted(
                            "\(how) \(list.joined(separator: ", ")) on \(ref). The page has them as if picked by hand; nothing is sent until the form is.",
                            done.page, l, browser, activity: "Attached \(files.count) file(s) on \(host(done.page.url))"
                        )
                    }
                }),
            ToolEntry(
                tool: .make(
                    "browser_download", title: "Save a File",
                    description:
                        "Saves the file a link points to, an address, or the page itself (a PDF the tab shows) into the Mac's Downloads folder.",
                    input: ["ref": .stringParam("A link"), "url": .stringParam("An address")], readOnly: false,
                    destructive: true, openWorld: true, deadlineMS: 30_000),
                handler: { args in
                    await run {
                        let ref = args["ref"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                        var url = args["url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                        if let u = url, !u.lowercased().hasPrefix("blob:"), !u.lowercased().hasPrefix("data:") {
                            url = try SafariBrowser.normalize(u)
                        }
                        let l = await route(browser, locked)
                        let saved = try await download(ref: ref, url: url, browser: browser, locked: l)
                        var r = ToolResult.text(saved.said)
                        r.activity = "Saved \(saved.file.lastPathComponent) to Downloads"
                        return await told(r, l, browser)
                    }
                }),
        ]
    }

    /// Saves a file (FR-438): fetched in the page first, with its cookies and session (also a
    /// file the page made itself, blob: and data:); when the page may not fetch it (another
    /// site's), by Latchkey itself with the Owner's Safari cookies.
    static func download(
        ref: String?, url: String?, browser: SafariBrowser, locked l: LockedBrowser?,
        folder: URL = BrowserDownloads.downloads
    ) async throws
        -> (file: URL, said: String)
    {
        let got =
            try await either(
                l, { try await $0.fetchFile(ref: ref, url: url, maxBytes: BrowserDownloads.pageLimit) },
                { try await browser.fetchFile(ref: ref, url: url, maxBytes: BrowserDownloads.pageLimit) })
        let f = got.fetched
        func said(_ file: URL, _ size: Int, _ type: String?, how: String) -> String {
            "Saved \(BrowserDownloads.size(size))\(type.map { ", \($0)" } ?? "") to \(file.path) (\(how)). Read it with files_read and that path; it is marked as downloaded from the web, as Safari marks downloads."
        }
        if f.state == "toobig" {
            throw Failure.failed(
                "The file is \(BrowserDownloads.size(f.size ?? 0)); Latchkey saves at most \(BrowserDownloads.size(BrowserDownloads.pageLimit)) through the page."
            )
        }
        if f.state == "done", let b64 = f.b64, let data = Data(base64Encoded: b64), (f.status ?? 200) < 400 {
            let name = BrowserDownloads.name(
                disposition: f.disposition, suggested: got.suggested, address: f.final ?? got.address, type: f.type)
            let file = try BrowserDownloads.save(data, name: name, from: got.address, in: folder)
            return (file, said(file, data.count, f.type, how: "fetched by the page, with its sign-in"))
        }
        if let status = f.status, status >= 400 {
            throw Failure.failed("The site answered \(status) for \(host(got.address)); nothing was saved.")
        }
        // The page may not fetch it (another site's file): Latchkey fetches it with Safari's cookies.
        guard got.address.lowercased().hasPrefix("http") else {
            throw Failure.failed("The page couldn't hand over the file (\(f.error ?? f.state)); nothing was saved.")
        }
        let cookies = SafariCookies.parse((try? Data(contentsOf: SafariCookies.file)) ?? Data()).compactMap(
            SafariCookies.httpCookie)
        let direct = try await BrowserDownloads.fetchDirect(got.address, cookies: cookies)
        let size = (try? FileManager.default.attributesOfItem(atPath: direct.file.path)[.size] as? Int) ?? 0
        let name = BrowserDownloads.name(
            disposition: direct.disposition, suggested: got.suggested, address: direct.final, type: direct.type)
        let file = try BrowserDownloads.move(direct.file, name: name, from: got.address, in: folder)
        return (
            file, said(file, size, direct.type, how: "fetched by Latchkey with Safari's cookies, as the page couldn't")
        )
    }
}
