import AppKit
import WebKit

/// A real mouse and keyboard for a page of Latchkey's own browser (spec 005 FR-478 to FR-485,
/// spec 013 FR-1377, plan D15; Toni, 2026-11-25: "an approach that looks as much as humans look
/// on browsers ... no complex tricks with JavaScript"). AppKit's own mouse and key events, made
/// here for the view's never-shown window and handed straight to the view, as WebKit's own tests
/// do: WebKit turns them into the page's trusted events and does what the browser does for them.
/// They never go through the window server, `NSApp.sendEvent` or a posted `CGEvent`, so no other
/// view, window, app or event monitor sees them, and the Owner's pointer and keyboard are never
/// touched (Constitution IV). Key characters are never logged (spec 013 FR-1377: a password
/// goes this way).
@MainActor
enum RealInput {
    /// Latchkey's own script world for finding where to click and for counting the events the
    /// page took: the page's scripts can't change what it uses (rule 1 of
    /// `.claude/rules/secrets-and-pages.md`).
    static let world = WKContentWorld.world(name: "latchkey-input")
    /// FR-485: the longest one step (a click, a key) waits for the page to take its events.
    static let stepLimit: Duration = .seconds(2)

    /// Counts the trusted pointer-up, mouse-up, key-up and input events, in every frame; a frame of
    /// the page's own site counts into the top page's count too. Added before the page's own
    /// scripts, on the window, while capturing, so the page can't stop it seeing them. The last
    /// trusted keydown is kept, to read whether the page took it (`defaultPrevented`).
    static let counter = """
        (function () {
          if (window.__lkInput) return;
          var c = { up: 0, key: 0, input: 0, last: null };
          try { Object.defineProperty(window, '__lkInput', { value: c }); } catch (x) { return; }
          var top = null;
          try { if (window.top !== window && window.top.__lkInput) top = window.top.__lkInput; } catch (x) { top = null; }
          function add(name) { return function (ev) { if (!ev.isTrusted) return; c[name]++; if (top) top[name]++; }; }
          window.addEventListener('pointerup', add('up'), true);
          window.addEventListener('mouseup', add('up'), true);
          window.addEventListener('keyup', add('key'), true);
          window.addEventListener('input', add('input'), true);
          window.addEventListener('keydown', function (ev) { if (ev.isTrusted) { c.last = ev; if (top) top.last = ev; } }, true);
        })();
        """

    static var userScript: WKUserScript {
        WKUserScript(source: counter, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    // MARK: where

    /// Where a person would click the element `ref` names: scrolled into view first, the middle of
    /// its first box that shows, in the top page's coordinates; and what is drawn there.
    struct Spot: Decodable, Sendable {
        var missing: Bool?
        /// FR-484: a list, colour, or date field: not clicked ("list", "colour", "date").
        var refuse: String?
        /// Nothing of it shows (no box on the page).
        var hidden: Bool?
        var x: Double?
        var y: Double?
        /// What is on top at that point when it isn't the element (FR-479).
        var covered: String?
        /// The element's tag and type, lower case: "input:text", "select", "button".
        var kind: String?
        /// A field that takes typing (input of a text kind, textarea, contenteditable).
        var field: Bool?
        /// It holds something (a field's value, an editor's text).
        var filled: Bool?
        /// A date or time field: typed into after `focus()`, not clicked (FR-484).
        var dateField: Bool?
    }

    /// The script that answers a `Spot` (JSON) for `ref`. `scroll`: scroll it into view first.
    static func spot(_ ref: String, scroll: Bool = true) -> String {
        // nosemgrep: latchkey-page-script-literal -- besides literal() and the fixed `deep`, only a Bool.
        """
        (function (ref, scroll) {
          \(PageScripts.deep)
          var e = __lkFind('[data-latchkey=' + JSON.stringify(ref) + ']');
          if (!e) return JSON.stringify({ missing: true });
          var tag = e.tagName.toLowerCase(), type = (e.getAttribute('type') || (tag === 'input' ? 'text' : '')).toLowerCase();
          var kind = tag + (tag === 'input' ? ':' + type : '');
          var out = { kind: kind };
          if (tag === 'select' && !e.multiple && !(e.size > 1)) { out.refuse = 'list'; return JSON.stringify(out); }
          if (tag === 'input' && type === 'color') { out.refuse = 'colour'; return JSON.stringify(out); }
          if (tag === 'input' && ['date', 'datetime-local', 'month', 'week', 'time'].indexOf(type) >= 0) { out.dateField = true; out.refuse = 'date'; }
          var texty = ['text', 'search', 'email', 'url', 'tel', 'password', 'number', ''].indexOf(type) >= 0;
          out.field = !!((tag === 'input' && texty) || tag === 'textarea' || e.isContentEditable);
          out.filled = out.field ? !!(e.isContentEditable ? (e.textContent || '').length : String(e.value || '').length) : false;
          var win = e.ownerDocument.defaultView;
          function box() {
            var rs = e.getClientRects();
            for (var i = 0; i < rs.length; i++) if (rs[i].width > 0 && rs[i].height > 0) return rs[i];
            return null;
          }
          var r = box();
          if (!r) { out.hidden = true; return JSON.stringify(out); }
          if (scroll && (r.top < 0 || r.left < 0 || r.bottom > win.innerHeight || r.right > win.innerWidth)) {
            e.scrollIntoView({ block: 'center', inline: 'center' });
            r = box();
            if (!r) { out.hidden = true; return JSON.stringify(out); }
          }
          var left = Math.max(r.left, 0), right = Math.min(r.right, win.innerWidth);
          var top = Math.max(r.top, 0), bottom = Math.min(r.bottom, win.innerHeight);
          if (right <= left || bottom <= top) { out.hidden = true; return JSON.stringify(out); }
          var x = (left + right) / 2, y = (top + bottom) / 2;
          // Into the top page's coordinates through frames of the same site.
          var w = win;
          while (w !== w.parent) {
            var fe = null;
            try { fe = w.frameElement; } catch (z) { fe = null; }
            if (!fe) break;
            var fr = fe.getBoundingClientRect(), fs = getComputedStyle(fe);
            x += fr.left + fe.clientLeft + (parseFloat(fs.paddingLeft) || 0);
            y += fr.top + fe.clientTop + (parseFloat(fs.paddingTop) || 0);
            w = w.parent;
          }
          out.x = x; out.y = y;
          function hitAt(doc, px, py) {
            var h = doc.elementFromPoint(px, py);
            while (h && h.shadowRoot) { var inner = h.shadowRoot.elementFromPoint(px, py); if (!inner || inner === h) break; h = inner; }
            if (h && (h.tagName === 'IFRAME' || h.tagName === 'FRAME')) {
              var d = null;
              try { d = h.contentDocument; } catch (z) { d = null; }
              if (d) {
                var hr = h.getBoundingClientRect(), hs = getComputedStyle(h);
                var inside = hitAt(d, px - hr.left - h.clientLeft - (parseFloat(hs.paddingLeft) || 0), py - hr.top - h.clientTop - (parseFloat(hs.paddingTop) || 0));
                if (inside) return inside;
              }
            }
            return h;
          }
          function within(n) { for (; n; n = n.parentNode || n.host) if (n === e) return true; return false; }
          var hit = hitAt(document, x, y);
          var label = e.labels && Array.prototype.some.call(e.labels, function (l) { return hit && l.contains(hit); });
          if (hit && !within(hit) && !label) {
            var named = hit;
            while (named && !(named.getAttribute && named.getAttribute('data-latchkey'))) named = named.parentNode || named.host;
            var words = (hit.innerText || hit.textContent || hit.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim().slice(0, 60);
            out.covered = (named ? named.getAttribute('data-latchkey') + ' ' : '') + hit.tagName.toLowerCase() + (words ? ' «' + words + '»' : '');
          }
          return JSON.stringify(out);
        })(\(PageScripts.literal(ref)), \(scroll ? "true" : "false"))
        """
    }

    /// What has the focus, as the input world sees it (through frames and shadow roots):
    /// "select" for a one-line list (FR-484), else its tag and reference, like "input e5".
    static let focused = """
        (function () {
          var a = document.activeElement;
          for (var k = 0; k < 20 && a; k++) {
            if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
            if (a.tagName === 'IFRAME' || a.tagName === 'FRAME') {
              var d = null;
              try { d = a.contentDocument; } catch (z) { d = null; }
              if (d && d.activeElement) { a = d.activeElement; continue; }
            }
            break;
          }
          if (!a || a === document.body || a === document.documentElement) return '';
          if (a.tagName === 'SELECT' && !a.multiple && !(a.size > 1)) return 'select';
          return a.tagName.toLowerCase() + (a.getAttribute('data-latchkey') ? ' ' + a.getAttribute('data-latchkey') : '');
        })()
        """

    /// Moves the focus to the element, as Tab would (a button or link Claude presses keys in,
    /// a date field): `focus()` in Latchkey's world; the keys after it are real.
    static func focus(_ ref: String) -> String {
        // nosemgrep: latchkey-page-script-literal -- besides literal() and the fixed `deep`, nothing.
        """
        (function (ref) {
          \(PageScripts.deep)
          var e = __lkFind('[data-latchkey=' + JSON.stringify(ref) + ']');
          if (!e) return 'missing';
          if (e.focus) e.focus();
          return 'ok';
        })(\(PageScripts.literal(ref)))
        """
    }

    // MARK: the mouse

    /// The window's point for a point of the page (CSS pixels from its top left): the view fills
    /// the window, whose own coordinates start at the bottom left.
    static func windowPoint(_ x: Double, _ y: Double, in view: WKWebView) -> NSPoint {
        let inView = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
        return view.convert(inView, to: nil)
    }

    private static var eventNumber = 0

    private static func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ window: NSWindow, clicks: Int) -> NSEvent? {
        eventNumber += 1
        return NSEvent.mouseEvent(
            with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
            pressure: type == .leftMouseDown ? 1 : 0)
    }

    /// The pointer moves onto the point (from a little to its left and above, as a hand brings
    /// it), as a mouse's moves do.
    static func move(to p: NSPoint, in view: WKWebView) async {
        guard let window = view.window else { return }
        for q in [NSPoint(x: p.x - 12, y: p.y + 8), p] {
            if let e = mouse(.mouseMoved, q, window, clicks: 0) { view.mouseMoved(with: e) }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    /// A click as a mouse makes it: the pointer moves there, presses, and lets go; then waits for
    /// the page to take the release (FR-485).
    static func click(at p: NSPoint, in view: WKWebView) async {
        guard let window = view.window else { return }
        let before = await count(view, "up")
        await move(to: p, in: view)
        if let e = mouse(.leftMouseDown, p, window, clicks: 1) { view.mouseDown(with: e) }
        try? await Task.sleep(for: .milliseconds(60))
        if let e = mouse(.leftMouseUp, p, window, clicks: 1) { view.mouseUp(with: e) }
        await wait(view, "up", after: before)
    }

    // MARK: the keyboard

    /// One key of a US keyboard: what it types, its key code (`kVK_*`), and its modifiers.
    struct Stroke: Equatable, Sendable {
        var characters: String
        var ignoringModifiers: String
        var keyCode: UInt16
        var flags: NSEvent.ModifierFlags
    }

    /// A US keyboard's keys for the characters it types without Shift, and with it.
    static let plain: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]
    static let shifted: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26, "_": 27, "*": 28, ")": 29,
        "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43, "?": 44, ">": 47, "~": 50,
    ]

    /// The key that types `ch` on a US keyboard; nil for a character no key types (FR-480:
    /// those arrive as text, `insertText`).
    static func stroke(for ch: Character) -> Stroke? {
        let s = String(ch)
        if ch == "\n" || ch == "\r" { return Stroke(characters: "\r", ignoringModifiers: "\r", keyCode: 36, flags: []) }
        if ch == "\t" { return Stroke(characters: "\t", ignoringModifiers: "\t", keyCode: 48, flags: []) }
        if let code = plain[ch] { return Stroke(characters: s, ignoringModifiers: s, keyCode: code, flags: []) }
        if ch.isASCII, ch.isUppercase, let lower = ch.lowercased().first, let code = plain[lower] {
            return Stroke(characters: s, ignoringModifiers: s, keyCode: code, flags: .shift)
        }
        if let code = shifted[ch] { return Stroke(characters: s, ignoringModifiers: s, keyCode: code, flags: .shift) }
        return nil
    }

    /// Keys by the name the page's `KeyboardEvent.key` gives them (`PageScripts.Key`): what the
    /// keyboard sends for each.
    static let named: [String: (String, UInt16, NSEvent.ModifierFlags)] = [
        "Enter": ("\r", 36, []), "Tab": ("\t", 48, []), "Escape": ("\u{1B}", 53, []),
        "Backspace": ("\u{7F}", 51, []), "Delete": ("\u{F728}", 117, .function), " ": (" ", 49, []),
        "ArrowUp": ("\u{F700}", 126, [.numericPad, .function]),
        "ArrowDown": ("\u{F701}", 125, [.numericPad, .function]),
        "ArrowLeft": ("\u{F702}", 123, [.numericPad, .function]),
        "ArrowRight": ("\u{F703}", 124, [.numericPad, .function]), "Home": ("\u{F729}", 115, .function),
        "End": ("\u{F72B}", 119, .function), "PageUp": ("\u{F72C}", 116, .function),
        "PageDown": ("\u{F72D}", 121, .function),
    ]

    /// The stroke for a key Claude names (`PageScripts.Key`), modifiers included; nil when no key
    /// of a US keyboard gives it.
    static func stroke(for key: PageScripts.Key) -> Stroke? {
        var s: Stroke
        if let n = named[key.key] {
            s = Stroke(characters: n.0, ignoringModifiers: n.0, keyCode: n.1, flags: n.2)
        } else if key.key.count == 1, let ch = key.key.first, let k = stroke(for: ch) {
            s = k
        } else {
            return nil
        }
        if key.shift { s.flags.insert(.shift) }
        if key.ctrl { s.flags.insert(.control) }
        if key.alt { s.flags.insert(.option) }
        if key.meta {
            s.flags.insert(.command)
            // With Command, a letter comes as itself (Cmd+A is "a").
            s.characters = s.ignoringModifiers.lowercased()
        }
        return s
    }

    private static func key(_ type: NSEvent.EventType, _ s: Stroke, _ window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: s.flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: s.characters,
            charactersIgnoringModifiers: s.ignoringModifiers, isARepeat: false, keyCode: s.keyCode)
    }

    /// Presses and releases one key, then waits for the page to take its release (FR-485).
    /// With Command it goes as a key equivalent, as AppKit sends shortcuts.
    static func press(_ s: Stroke, in view: WKWebView) async {
        guard let window = view.window else { return }
        let before = await count(view, "key")
        if let down = key(.keyDown, s, window) {
            if s.flags.contains(.command) {
                _ = view.performKeyEquivalent(with: down)
            } else {
                view.keyDown(with: down)
            }
        }
        try? await Task.sleep(for: .milliseconds(25))
        if let up = key(.keyUp, s, window) { view.keyUp(with: up) }
        await wait(view, "key", after: before)
    }

    /// Text no key of a US keyboard types (é, an emoji), as the Character Viewer gives it: input
    /// without a key (FR-480).
    static func insert(_ text: String, in view: WKWebView) async {
        let before = await count(view, "input")
        // The responder's insertText, which the view takes as an input method's text.
        view.insertText(text)
        await wait(view, "input", after: before)
    }

    /// Types `text` into what has the focus, a key per character (FR-480). `check`: before each
    /// character, whether typing may go on (spec 013 FR-1377: the focus is still on the checked
    /// field); typing stops when it answers false. Answers how many characters were typed.
    static func type(_ text: String, in view: WKWebView, check: (() async -> Bool)? = nil) async -> Int {
        var n = 0
        for ch in text {
            if let check, !(await check()) { return n }
            if let s = stroke(for: ch) { await press(s, in: view) } else { await insert(String(ch), in: view) }
            n += 1
        }
        return n
    }

    /// Whether the page took the last key (its keydown was cancelled), as the input world saw it.
    static func lastKeyTaken(_ view: WKWebView) async -> Bool {
        await evaluate(view, "window.__lkInput && __lkInput.last ? String(__lkInput.last.defaultPrevented) : 'false'")
            == "true"
    }

    // MARK: waiting

    /// One of the input world's counts ("up", "key", "input"), or -1 when the page didn't answer
    /// in time (a page held on a dialog runs no script).
    static func count(_ view: WKWebView, _ name: String) async -> Int {
        Int(await evaluate(view, "window.__lkInput ? String(__lkInput.\(name)) : '-1'") ?? "-1") ?? -1
    }

    /// Runs `code` in the input world, at most `within` (Constitution II: a page held on a
    /// dialog never answers).
    static func evaluate(_ view: WKWebView, _ code: String, within: Duration = .milliseconds(500)) async -> String? {
        await Deadline.first(within: within) { @MainActor @Sendable in
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                view.evaluateJavaScript(code, in: nil, in: world) { result in
                    switch result {
                    case .success(let value):
                        c.resume(returning: (value as? String) ?? (value as? NSNumber)?.stringValue)
                    case .failure: c.resume(returning: nil)
                    }
                }
            }
        }
    }

    /// Waits until the count `name` is past `before`, at most `stepLimit` (FR-485). A page that
    /// never gets the event (a disabled button takes none) costs that wait once.
    static func wait(_ view: WKWebView, _ name: String, after before: Int) async {
        let end = ContinuousClock.now + stepLimit
        while ContinuousClock.now < end {
            let n = await count(view, name)
            if n < 0 || n > before { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// The never-shown window of a page of Latchkey's own browser (`LockedBrowser.holder`). It says
/// it is the key window only while Claude acts in the page (`active`, spec 005 FR-483), which is
/// what WebKit asks to count the page focused; AppKit never makes it key, it never comes
/// forward, and the app is never activated (Constitution IV). Why not always: while a password
/// field has the focus in a window that says it is key, WebKit turns on secure keyboard entry
/// for the whole Mac.
final class HolderWindow: NSWindow {
    var active = false {
        didSet {
            guard active != oldValue else { return }
            // WebKit reads isKeyWindow when its window's key notifications come; this window's
            // only (`object: self`).
            NotificationCenter.default.post(
                name: active ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: self)
        }
    }
    override var isKeyWindow: Bool { active }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
