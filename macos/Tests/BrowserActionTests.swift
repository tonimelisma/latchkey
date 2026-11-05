import Foundation
import Testing
import WebKit

@testable import Latchkey

/// Spec 005 FR-433 to FR-439 (2026-11-05, Toni: "all the safari stuff"): keys, hover,
/// scrolling, lists, files into and out of the page, and the copy a picture is drawn from. The
/// page scripts run in a real WebKit view (the engine Safari uses); the tools run against the
/// stand-in Safari; real Safari is checked by `scripts/safari-check.sh`.
enum ActionPage {
    static let html = """
        <html><head><title>Actions</title>
        <style>#submenu { display: none; } #box { height: 80px; overflow: auto; } #box div { height: 900px; }
        #tall { height: 3000px; } #pic { display: none; }</style></head><body>
        <form id="f" onsubmit="document.title = 'sent:' + document.getElementById('name').value; return false;">
          <input id="name" placeholder="Name"><input id="other" placeholder="Other">
          <input id="pw" type="password">
        </form>
        <p id="keys">keys:</p>
        <select id="size"><option value="s">Small</option><option value="m">Medium</option><option value="l">Large</option></select>
        <select id="extras" multiple><option>Cheese</option><option>Ham</option><option>Olives</option></select>
        <button id="combo" role="combobox" aria-haspopup="listbox" aria-controls="colors"
          onclick="document.getElementById('colors').hidden = false">Pick a color</button>
        <ul id="colors" role="listbox" hidden>
          <li role="option" onclick="document.getElementById('picked').textContent = 'picked:red'">Red</li>
          <li role="option" onclick="document.getElementById('picked').textContent = 'picked:blue'">Blue</li>
        </ul>
        <p id="picked">picked:</p>
        <div id="menu" aria-haspopup="true" onmouseenter="document.getElementById('submenu').style.display = 'block'">Products</div>
        <div id="submenu"><a href="#p">Hidden product</a></div>
        <div id="box"><div>Inside the box</div></div>
        <button id="pick" onclick="document.getElementById('pic').click()">Upload a photo</button>
        <input id="pic" type="file">
        <label>Attach <input id="file" type="file" multiple></label>
        <p id="filelog">files:</p>
        <div id="drop" role="button">Drop here</div>
        <p id="droplog">dropped:</p>
        <a id="blob" href="#" download="made.txt">Save made</a>
        <a id="data" href="data:text/plain;base64,aGVsbG8=" download="hello.txt">Save data</a>
        <div id="tall">Tall</div>
        <script>
          document.addEventListener('keydown', function (e) { document.getElementById('keys').textContent += ' ' + e.key; });
          ['file', 'pic'].forEach(function (id) {
            document.getElementById(id).addEventListener('change', function (e) {
              Array.prototype.forEach.call(e.target.files, function (f) {
                f.text().then(function (t) { document.getElementById('filelog').textContent += ' ' + f.name + '=' + t; });
              });
            });
          });
          var drop = document.getElementById('drop');
          drop.addEventListener('dragover', function (e) { e.preventDefault(); });
          drop.addEventListener('drop', function (e) {
            e.preventDefault();
            document.getElementById('droplog').textContent += ' ' + e.dataTransfer.files[0].name;
          });
          document.getElementById('blob').href = URL.createObjectURL(new Blob(['made by the page'], { type: 'text/plain' }));
        </script>
        </body></html>
        """
}

@MainActor @Suite(.serialized) struct PageActionScriptTests {
    func page() async throws -> (TestPage, PageScripts.Page) {
        let p = TestPage()
        try await p.load(ActionPage.html)
        return (p, try PageScripts.decode(try await p.run(PageScripts.read(offset: 0))))
    }

    func ref(_ r: PageScripts.Page, _ kind: String, _ label: String) throws -> String {
        try #require(r.elements.first { $0.kind.hasPrefix(kind) && $0.label.contains(label) }?.ref, "\(kind) \(label)")
    }

    /// The parts after "ok" and a tab.
    func detail(_ answer: String) throws -> String { try SafariBrowser.detail(answer, ref: "") }

    @Test func readListsHiddenFileFieldsPopupsAndScrollingParts() async throws {
        let (_, r) = try await page()
        let pic = try #require(r.elements.first { $0.kind == "field:file" && $0.label.contains("hidden file field") })
        #expect(!pic.ref.isEmpty, "a file field the page hides behind its own button is listed")
        #expect(r.elements.contains { $0.kind == "field:file" && $0.label.contains("Attach") }, "labelled by its label")
        #expect(r.elements.contains { $0.kind == "combobox" && $0.label == "Pick a color" })
        #expect(r.elements.contains { $0.kind == "div" && $0.label == "Products" }, "a menu that opens on hover")
        #expect(r.elements.contains { $0.kind == "scrollable" && $0.label.contains("Inside the box") })
    }

    @Test func keysTypeSendMoveTheFocusAndReachThePage() async throws {
        let (p, r) = try await page()
        let name = try ref(r, "field:text", "Name")
        let keys = try ["o", "k", "Enter"].map(PageScripts.Key.init)
        let did = try detail(try await p.run(PageScripts.keys(keys, ref: name)))
        #expect(did.contains("Enter: sent the form"), "\(did)")
        #expect(try await p.run("document.title") == "sent:ok")
        #expect(try await p.run("document.getElementById('keys').textContent") == "keys: o k Enter")
        let tab = try detail(try await p.run(PageScripts.keys([try PageScripts.Key("Tab")], ref: name)))
        #expect(tab.contains("moved the focus"), "\(tab)")
        #expect(try await p.run("document.activeElement.id") == "other")
        _ = try await p.run(PageScripts.keys(try ["cmd+a", "Backspace"].map(PageScripts.Key.init), ref: name))
        #expect(try await p.run("document.getElementById('name').value") == "")
        let size = try ref(r, "choice", "Small")
        _ = try await p.run(PageScripts.keys([try PageScripts.Key("ArrowDown")], ref: size))
        #expect(try await p.run("document.getElementById('size').value") == "m", "an arrow changes a list's choice")
        _ = try await p.run(PageScripts.keys([try PageScripts.Key("Escape")], ref: nil))
        #expect(try await p.run("document.getElementById('keys').textContent").hasSuffix("Escape"))
        #expect(try await p.run(PageScripts.keys([try PageScripts.Key("Enter")], ref: "e999")) == "missing")
    }

    @Test func keyNames() throws {
        #expect(try PageScripts.Key("Return").key == "Enter")
        #expect(try PageScripts.Key("esc").key == "Escape")
        let s = try PageScripts.Key("cmd+shift+z")
        #expect(s.key == "Z" && s.meta && s.shift && !s.ctrl)
        #expect(try PageScripts.Key("ctrl++").key == "+")
        #expect(try PageScripts.Key("arrow_down").key == "ArrowDown")
        #expect(throws: PageScripts.Key.Unknown.self) { try PageScripts.Key("hyper+a") }
        #expect(throws: PageScripts.Key.Unknown.self) { try PageScripts.Key("Launch") }
    }

    @Test func hoverOpensAMenuThatOpensOnHover() async throws {
        let (p, r) = try await page()
        let shown = try detail(try await p.run(PageScripts.hover(try ref(r, "div", "Products"))))
        #expect((Int(shown) ?? 0) > 0)
        #expect(try await p.run("getComputedStyle(document.getElementById('submenu')).display") == "block")
    }

    @Test func scrollsThePageAndAPartOfIt() async throws {
        let (p, r) = try await page()
        let down = try JSONDecoder().decode(
            PageScripts.ScrollPosition.self,
            from: Data(try detail(try await p.run(PageScripts.scroll(nil, direction: "down", amount: 400))).utf8))
        #expect(down.y == 400 && !down.element && down.moved)
        #expect(down.said.contains("400 of"))
        let box = try JSONDecoder().decode(
            PageScripts.ScrollPosition.self,
            from: Data(
                try detail(
                    try await p.run(
                        PageScripts.scroll(try ref(r, "scrollable", "Inside"), direction: "bottom", amount: nil))
                ).utf8))
        #expect(box.element && box.y == box.maxY && box.y > 0)
        #expect(box.said.contains("at the bottom"))
        let top = try detail(try await p.run(PageScripts.scroll(nil, direction: "top", amount: nil)))
        #expect(top.contains("\"y\":0"))
    }

    @Test func choosesFromListsAndSaysWhatAListHas() async throws {
        let (p, r) = try await page()
        #expect(
            try detail(try await p.run(PageScripts.choose(try ref(r, "choice", "Small"), options: ["Large"])))
                == "[\"Large\"]")
        #expect(try await p.run("document.getElementById('size').value") == "l")
        let two = try detail(
            try await p.run(PageScripts.choose(try ref(r, "choice", "Cheese"), options: ["Cheese", "Olives"])))
        #expect(two == "[\"Cheese\",\"Olives\"]")
        _ = try await p.run(PageScripts.choose(try ref(r, "combobox", "Pick"), options: ["Blue"]))
        #expect(try await p.run("document.getElementById('picked').textContent") == "picked:blue")
        let none = try await p.run(PageScripts.choose(try ref(r, "choice", "Small"), options: ["Purple"]))
        #expect(throws: SafariBrowser.Failure.self) { try SafariBrowser.detail(none, ref: "e1") }
        #expect(none.hasPrefix("nooption\t") && none.contains("Medium"))
    }

    @Test func attachesFilesToAFieldAHiddenFieldAndADropPlace() async throws {
        let (p, r) = try await page()
        let a = PageScripts.Attachment(name: "a.txt", type: "text/plain", data: Data("one".utf8))
        let b = PageScripts.Attachment(name: "b.txt", type: "text/plain", data: Data("two".utf8))
        #expect(
            try detail(try await p.run(PageScripts.attach(try ref(r, "field:file", "Attach"), files: [a, b])))
                == "[\"field\",2]")
        let hidden = try #require(r.elements.first { $0.label.contains("hidden file field") }).ref
        #expect(try await p.run(PageScripts.attach(hidden, files: [a, b])) == "single", "one file only")
        _ = try await p.run(PageScripts.attach(hidden, files: [b]))
        #expect(try await p.run(PageScripts.attach(try ref(r, "button", "Drop"), files: [a])).contains("dropped"))
        var log = ""
        for _ in 0..<50 where !log.contains("b.txt=two") {
            try await Task.sleep(for: .milliseconds(20))
            log = try await p.run("document.getElementById('filelog').textContent")
        }
        #expect(log.contains("a.txt=one") && log.contains("b.txt=two"), "\(log)")
        #expect(try await p.run("document.getElementById('droplog').textContent") == "dropped: a.txt")
        #expect(try await p.run(PageScripts.attach(try ref(r, "field:text", "Name"), files: [a])) == "notfile")
    }

    @Test func fetchesAFileThePageMadeOrALinkNames() async throws {
        let (p, r) = try await page()
        for (label, name, text) in [("Save made", "made.txt", "made by the page"), ("Save data", "hello.txt", "hello")]
        {
            let start = try PageScripts.DownloadStart.decode(
                try detail(
                    try await p.run(
                        PageScripts.startDownload(ref: try ref(r, "link", label), url: nil, limit: 1_000_000))))
            #expect(start.suggested == name)
            var f = PageScripts.Fetched(state: "running")
            for _ in 0..<100 where f.state == "running" {
                try await Task.sleep(for: .milliseconds(20))
                f = try PageScripts.Fetched.decode(try await p.run(PageScripts.takeDownload))
            }
            #expect(f.state == "done", "\(label): \(f.state) \(f.error ?? "")")
            #expect(Data(base64Encoded: f.b64 ?? "").map { String(decoding: $0, as: UTF8.self) } == text)
            #expect(
                try PageScripts.Fetched.decode(try await p.run(PageScripts.takeDownload)).state == "none", "taken once")
        }
        let tooBig = try PageScripts.DownloadStart.decode(
            try detail(
                try await p.run(PageScripts.startDownload(ref: try ref(r, "link", "Save made"), url: nil, limit: 3))))
        #expect(tooBig.address.hasPrefix("blob:"))
        var f = PageScripts.Fetched(state: "running")
        for _ in 0..<100 where f.state == "running" {
            try await Task.sleep(for: .milliseconds(20))
            f = try PageScripts.Fetched.decode(try await p.run(PageScripts.takeDownload))
        }
        #expect(f.state == "toobig")
    }

    /// The copy a picture is drawn from holds what fields hold now, never a password, and no
    /// script of the page's (FR-439, FR-410).
    @Test func thePictureCopyIsThePageAsItIsWithoutSecretsOrScripts() async throws {
        let (p, _) = try await page()
        _ = try await p.run(
            "document.getElementById('name').value = 'typed'; document.getElementById('pw').value = 'hunter2'; document.getElementById('size').value = 'l'; 1"
        )
        let copy = try PageScripts.PictureCopy.decode(try await p.run(PageScripts.pictureCopy(limit: 1_000_000)))
        #expect(copy.html.contains("value=\"typed\""))
        #expect(!copy.html.contains("hunter2"))
        #expect(!copy.html.contains("<script>") && copy.html.contains("script-src 'none'"))
        #expect(copy.html.contains("<option value=\"l\" selected"))
        #expect(copy.url == "https://shop.example.com/" && !copy.cut)
    }
}

/// The same actions in Latchkey's own browser, used while the Mac is locked (FR-420).
@MainActor @Suite struct LockedBrowserActionTests {
    let base = URL(string: "https://test.example/")!

    @Test func everyActionWorksInLatchkeysOwnBrowser() async throws {
        let b = LockedBrowser()
        defer { b.discard() }
        let r = try await b.open(html: ActionPage.html, base: base)
        func ref(_ kind: String, _ label: String) throws -> String {
            try #require(r.elements.first { $0.kind.hasPrefix(kind) && $0.label.contains(label) }?.ref)
        }
        let typed = try await b.press(
            try ["h", "i", "Enter"].map(PageScripts.Key.init), ref: try ref("field:text", "Name"))
        #expect(typed.page.title == "sent:hi")
        let chose = try await b.choose(try ref("choice", "Small"), options: ["Medium"])
        #expect(chose.detail == "[\"Medium\"]")
        let hovered = try await b.hover(try ref("div", "Products"))
        #expect(hovered.page.elements.contains { $0.label == "Hidden product" })
        let scrolled = try await b.scroll(nil, direction: "down", amount: 300)
        #expect(scrolled.detail.contains("\"y\":300"))
        let attached = try await b.attach(
            try ref("field:file", "Attach"), files: [.init(name: "x.txt", type: "text/plain", data: Data("x".utf8))])
        #expect(attached.detail == "[\"field\",1]")
        let got = try await b.fetchFile(ref: try ref("link", "Save made"), url: nil, maxBytes: 1_000_000)
        #expect(got.fetched.state == "done" && got.suggested == "made.txt")
        do {
            _ = try await b.choose(try ref("choice", "Small"), options: ["Purple"])
            Issue.record("an option that isn't there")
        } catch SafariBrowser.Failure.noOption(let said) {
            #expect(said.contains("Large"))
        }
    }

    /// FR-439: a picture drawn from the copy of a page, with no screen.
    @Test func drawsAPictureFromAPageCopy() async throws {
        let html =
            "<!DOCTYPE html><html><head><title>T</title></head><body style='background:#c00'><h1>Drawn</h1><input value='kept'></body></html>"
        let copy = PageScripts.PictureCopy(
            url: "https://test.example/", title: "T", width: 800, height: 600, x: 0, y: 0, cut: false, html: html)
        let image = try await LockedBrowser.draw(copy)
        #expect(image.data.count > 1_000)
        #expect(["image/png", "image/jpeg"].contains(image.mimeType))
        await #expect(throws: SafariBrowser.Failure.self) {
            _ = try await LockedBrowser.draw(
                PageScripts.PictureCopy(
                    url: "file:///etc/", title: "", width: 1, height: 1, x: 0, y: 0, cut: false, html: html))
        }
    }
}

/// Saving files and reading files to attach (FR-437, FR-438), in folders of the test's own.
@Suite struct BrowserDownloadTests {
    func folder() throws -> URL {
        let f = FileManager.default.temporaryDirectory.appending(path: "latchkey-downloads-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    @Test func namesComeFromTheServerTheLinkOrTheAddress() {
        #expect(
            BrowserDownloads.name(
                disposition: "attachment; filename=\"plain.pdf\"; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf",
                suggested: "x",
                address: "https://a.example/b", type: nil) == "résumé.pdf")
        #expect(
            BrowserDownloads.name(
                disposition: "attachment; filename=\"report.csv\"", suggested: nil, address: "https://a.example/b",
                type: nil) == "report.csv")
        #expect(
            BrowserDownloads.name(disposition: nil, suggested: "mine.txt", address: "https://a.example/b", type: nil)
                == "mine.txt")
        #expect(
            BrowserDownloads.name(
                disposition: nil, suggested: "", address: "https://a.example/files/Q3%20report.pdf", type: nil)
                == "Q3 report.pdf")
        #expect(
            BrowserDownloads.name(
                disposition: nil, suggested: nil, address: "https://a.example/", type: "application/pdf")
                == "download.pdf")
        // A name can't leave the folder or hide itself.
        let sneaky = BrowserDownloads.name(
            disposition: "attachment; filename=\"../../.zshrc\"", suggested: nil, address: "https://a.example/",
            type: nil)
        #expect(!sneaky.contains("/") && !sneaky.hasPrefix("."))
        #expect(BrowserDownloads.clean(String(repeating: "a", count: 300) + ".pdf").count == 200)
    }

    @Test func savesNeverOverAnotherFileAndMarksItDownloaded() throws {
        let f = try folder()
        defer { try? FileManager.default.removeItem(at: f) }
        let one = try BrowserDownloads.save(Data("1".utf8), name: "a.txt", from: "https://a.example/a.txt", in: f)
        let two = try BrowserDownloads.save(Data("2".utf8), name: "a.txt", from: "https://a.example/a.txt", in: f)
        #expect(one.lastPathComponent == "a.txt" && two.lastPathComponent == "a 2.txt")
        #expect(try String(contentsOf: one, encoding: .utf8) == "1")
        #expect(getxattr(two.path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "marked as downloaded from the web")
    }

    @Test func attachmentsAreFilesOfTheMac() throws {
        let f = try folder()
        defer { try? FileManager.default.removeItem(at: f) }
        let file = f.appending(path: "photo.png")
        try Data([1, 2, 3]).write(to: file)
        let got = try BrowserDownloads.attachments([file.path])
        #expect(got == [PageScripts.Attachment(name: "photo.png", type: "image/png", data: Data([1, 2, 3]))])
        #expect(throws: SafariBrowser.Failure.self) { try BrowserDownloads.attachments([f.path]) }
        #expect(throws: SafariBrowser.Failure.self) {
            try BrowserDownloads.attachments([f.appending(path: "none").path])
        }
        #expect(throws: SafariBrowser.Failure.self) { try BrowserDownloads.attachments([file.path], limit: 2) }
    }

    /// A long script (a file Claude attaches) goes to Safari through a file only this user can
    /// read, removed right after.
    @Test func longScriptsTravelThroughAFile() throws {
        let short = try SafariBrowser.ScriptFile("1")
        #expect(short.argument == "1")
        let long = try SafariBrowser.ScriptFile(String(repeating: "x", count: SafariBrowser.argumentLimit + 1))
        #expect(long.argument.hasPrefix(SafariBrowser.fileMark))
        let path = String(long.argument.dropFirst(SafariBrowser.fileMark.count))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        long.remove()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

/// Answers the download scripts like Safari: the start, then the file once.
final class DownloadSafari: ScriptRunner, @unchecked Sendable {
    let fake = FakeSafari()
    var fetched =
        #"{"state":"done","status":200,"type":"text/plain","disposition":"attachment; filename=\"r.txt\"","final":"https://shop.example.com/r","size":2,"b64":"aGk="}"#

    func run(_ script: String, _ args: [String]) async throws -> String {
        if script == SafariBrowser.Script.javaScript, args.count > 1 {
            if args[1].contains("__latchkeyDownload', { value") {
                return "[]\nok\t{\"address\":\"https://shop.example.com/r\",\"suggested\":\"\"}"
            }
            if args[1].contains("var j = window.__latchkeyDownload") { return "[]\n" + fetched }
        }
        return try await fake.run(script, args)
    }
}

@Suite struct BrowserActionToolTests {
    func tools(_ runner: any ScriptRunner) -> [String: ToolEntry] {
        let b = SafariBrowser(scripts: runner)
        let all = BrowserCapability.readTools(browser: b) + BrowserCapability.writeTools(browser: b)
        return Dictionary(uniqueKeysWithValues: all.map { ($0.tool.name, $0) })
    }

    @Test func browserActTakesTheNewActions() async throws {
        let t = tools(FakeSafari())
        let act = try #require(t["browser_act"])
        let schema = act.tool.inputSchema.jsonText
        for a in ["select", "key", "hover", "scroll", "upload", "download"] { #expect(schema.contains(a), "\(a)") }
        _ = await t["browser_read"]!.handler(.object(["url": .string("https://shop.example.com")]))
        let calls: [[String: JSONValue]] = [
            ["action": .string("key"), "keys": .string("Tab Enter")],
            ["action": .string("hover"), "ref": .string("e1")],
            ["action": .string("scroll"), "direction": .string("down")],
            ["action": .string("select"), "ref": .string("e1"), "options": .array([.string("Large")])],
        ]
        for args in calls {
            let r = await act.handler(.object(args))
            #expect(!r.isError, "\(args): \(r.content.jsonText)")
            #expect(r.activity != nil, "FR-408: \(args)")
        }
        let badKey = await act.handler(.object(["action": .string("key"), "keys": .string("hyper+q")]))
        #expect(badKey.isError && badKey.content.jsonText.contains("doesn't know the key"))
        let noFile = await act.handler(
            .object([
                "action": .string("upload"), "ref": .string("e1"),
                "paths": .array([.string("/nonexistent/latchkey-test-file")]),
            ]))
        #expect(noFile.isError && noFile.content.jsonText.contains("no file"))
        let badDir = await act.handler(.object(["action": .string("scroll"), "direction": .string("sideways")]))
        #expect(badDir.isError)
    }

    @Test func aDownloadIsSavedWithItsNameAndTheAnswerNamesThePath() async throws {
        let runner = DownloadSafari()
        let b = SafariBrowser(scripts: runner)
        _ = try await b.open("https://shop.example.com", newTab: false)
        let folder = FileManager.default.temporaryDirectory.appending(path: "latchkey-dl-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = try await BrowserCapability.download(ref: "e1", url: nil, browser: b, locked: nil, folder: folder)
        #expect(saved.file.lastPathComponent == "r.txt")
        #expect(try String(contentsOf: saved.file, encoding: .utf8) == "hi")
        #expect(saved.said.contains(saved.file.path) && saved.said.contains("files_read"))
        runner.fetched = #"{"state":"done","status":404,"size":0,"b64":""}"#
        await #expect(throws: SafariBrowser.Failure.self) {
            _ = try await BrowserCapability.download(ref: "e1", url: nil, browser: b, locked: nil, folder: folder)
        }
        runner.fetched = #"{"state":"toobig","size":99000000}"#
        await #expect(throws: SafariBrowser.Failure.self) {
            _ = try await BrowserCapability.download(ref: "e1", url: nil, browser: b, locked: nil, folder: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["r.txt"], "nothing more saved")
    }
}
