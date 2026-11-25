import AppKit
import WebKit

/// A real mouse and keyboard for a page of Latchkey's own browser (spec 005 FR-478 to FR-485,
/// spec 013 FR-1377, plan D15; Toni, 2026-11-25: "an approach that looks as much as humans look
/// on browsers ... no complex tricks with JavaScript"). AppKit's own mouse and key events, made
/// here for the view's never-shown window and handed straight to the view, as WebKit's own tests
/// do: WebKit turns them into the page's trusted events and does what the browser does for them.
/// They never go through the window server or a posted `CGEvent`, so no other app sees them, and
/// the Owner's pointer and keyboard are never touched (Constitution IV). A key the page doesn't
/// take WebKit hands back to the app, as Safari's does, where a Command shortcut could reach
/// Latchkey's own menu: so only harmless shortcuts are pressed (`allowedCommand`, security
/// review 2026-11-25). Key characters are never logged (spec 013 FR-1377: a password goes this
/// way).
@MainActor
enum RealInput {
    /// Latchkey's own script world for finding where to click and for counting the events the
    /// page took: the page's scripts can't change what it uses (rule 1 of
    /// `.claude/rules/secrets-and-pages.md`).
    static let world = WKContentWorld.world(name: "latchkey-input")
    /// FR-485: the longest one step (a click, a key) waits for the page to take its events.
    static let stepLimit: Duration = .seconds(10)

    /// Tells Latchkey, as each one comes, of the trusted pointer-up, mouse-up, key-up and input
    /// events, in every frame, through a message handler only this world has (`InputSignal`):
    /// nothing asks the page (asking it after every key kept a busy Mac busier, GitHub's runner
    /// 2026-11-25). Added before the page's own scripts, on the window, while capturing, so the
    /// page can't stop it seeing them. With each key-up, whether the page took the key down
    /// (`defaultPrevented`); with each keypress and beforeinput, the reference of the element the
    /// character went into, inside shadow roots too (spec 013 FR-1377).
    static let counter = """
        (function () {
          if (window.__lkInput) return;
          try { Object.defineProperty(window, '__lkInput', { value: true }); } catch (x) { return; }
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.latchkeyInput;
          if (!h) return;
          var last = null;
          function send(m) { try { h.postMessage(m); } catch (x) {} }
          function up(ev) { if (ev.isTrusted) send({ k: 'up' }); }
          window.addEventListener('pointerup', up, true);
          window.addEventListener('mouseup', up, true);
          window.addEventListener('keydown', function (ev) { if (ev.isTrusted) last = ev; }, true);
          window.addEventListener('keyup', function (ev) { if (ev.isTrusted) send({ k: 'key', p: !!(last && last.defaultPrevented) }); }, true);
          window.addEventListener('input', function (ev) { if (ev.isTrusted) send({ k: 'input' }); }, true);
          function went(ev) {
            if (!ev.isTrusted) return;
            var t = ev.composedPath ? ev.composedPath()[0] : ev.target;
            // The node itself, marked by Latchkey in this world (`markField`), and this world's own
            // getters: the page can copy a reference or a type attribute, not the node (security
            // review 2026-11-25).
            var mine = !!(window.__lkField && t === window.__lkField);
            send({ k: 'target', t: mine ? 'field' : 'other', y: String((t && t.tagName === 'INPUT' && t.type) || '') });
          }
          window.addEventListener('keypress', went, true);
          window.addEventListener('beforeinput', went, true);
        })();
        """

    static let handlerName = "latchkeyInput"

    /// Marks the element `ref` names as the field the next characters must go into, in this
    /// world of the frame it is in (spec 013 FR-1377); "ok" or "missing".
    static func markField(_ ref: String) -> String {
        // nosemgrep: latchkey-page-script-literal -- besides literal() and the fixed `deep`, nothing.
        """
        (function (ref) {
          \(PageScripts.deep)
          var e = __lkFind('[data-latchkey=' + JSON.stringify(ref) + ']');
          if (!e) return 'missing';
          var w = e.ownerDocument && e.ownerDocument.defaultView;
          if (!w) return 'missing';
          w.__lkField = e;
          return 'ok';
        })(\(PageScripts.literal(ref)))
        """
    }

    static var userScript: WKUserScript {
        WKUserScript(source: counter, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    /// The Owner's clipboard stays out of reach (Constitution IV; security review 2026-11-25): a
    /// real click or key lets a page copy, cut, or read the clipboard, and a read shows WebKit's
    /// own Paste menu. In the page's world, before its scripts, in every frame: the clipboard API
    /// refuses, and copy, cut, and paste commands do nothing. Not to make a page work (FR-488).
    static let noClipboard = """
        (function () {
          try {
            var refuse = function () { return Promise.reject(new DOMException('The clipboard is not available.', 'NotAllowedError')); };
            var places = [window.Clipboard && Clipboard.prototype, navigator.clipboard].filter(Boolean);
            places.forEach(function (c) {
              ['read', 'readText', 'write', 'writeText'].forEach(function (k) {
                try { Object.defineProperty(c, k, { value: refuse, writable: false, configurable: false }); } catch (x) {}
              });
            });
            var ex = Document.prototype.execCommand;
            Object.defineProperty(Document.prototype, 'execCommand', { value: function (cmd) {
              if (/^(copy|cut|paste)$/i.test(String(cmd))) return false;
              return ex.apply(this, arguments);
            }, writable: false, configurable: false });
          } catch (x) {}
        })();
        """

    static var clipboardScript: WKUserScript {
        WKUserScript(source: noClipboard, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    /// Command shortcuts pressed in a page (FR-481): select all, undo and redo, and Command with
    /// an arrow or Backspace (moving and deleting in a field). Any other could reach Latchkey's
    /// own menu when the page doesn't take it (Cmd+Q quits, Cmd+, opens Settings on the screen).
    static func allowedCommand(_ k: PageScripts.Key) -> Bool {
        guard k.meta else { return true }
        let key = k.key.lowercased()
        if key == "a" { return !k.shift && !k.alt && !k.ctrl }
        if key == "z" { return !k.alt && !k.ctrl }
        return ["arrowup", "arrowdown", "arrowleft", "arrowright", "backspace"].contains(key) && !k.ctrl
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
          if (tag === 'label' && e.control) { var ct = e.control; var ctt = (ct.getAttribute('type') || '').toLowerCase(); if ((ct.tagName === 'SELECT' && !ct.multiple && !(ct.size > 1)) || ctt === 'color' || ['date', 'datetime-local', 'month', 'week', 'time'].indexOf(ctt) >= 0) { out.refuse = 'picker'; return JSON.stringify(out); } }
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
          function picker(n) {
            for (; n && n.tagName; n = n.parentNode || n.host) {
              var nt = (n.getAttribute('type') || '').toLowerCase();
              if (n.tagName === 'SELECT' && !n.multiple && !(n.size > 1)) return true;
              if (n.tagName === 'INPUT' && (nt === 'color' || ['date', 'datetime-local', 'month', 'week', 'time'].indexOf(nt) >= 0)) return true;
              if (n.tagName === 'LABEL' && n.control && n.control !== e && picker(n.control)) return true;
            }
            return false;
          }
          if (hit && !within(hit) && !label) {
            if (picker(hit)) out.refuse = 'picker';
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
          var at = (a.getAttribute('type') || '').toLowerCase();
          if (a.tagName === 'INPUT' && (at === 'color' || ['date', 'datetime-local', 'month', 'week', 'time'].indexOf(at) >= 0)) return 'select';
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

    /// Presses and releases one key. With `wait`, then waits until the page has taken every key
    /// sent so far (FR-485); without, the next key may follow at once: WebKit hands a page its
    /// keys in the order they came, so only a step that isn't a key (text, a script, a click)
    /// waits for them (`settle`). With Command it goes as a key equivalent, as AppKit sends
    /// shortcuts.
    @discardableResult
    static func press(_ s: Stroke, in view: WKWebView, wait: Bool = true) async -> Bool {
        guard let window = view.window else { return false }
        let signal = signals[ObjectIdentifier(view)]
        signal?.sentKeys += 1
        // Where this key's character goes is told afresh: an older word never counts for it.
        signal?.clearTarget()
        if let down = key(.keyDown, s, window) {
            if s.flags.contains(.command) {
                _ = view.performKeyEquivalent(with: down)
            } else {
                view.keyDown(with: down)
            }
        }
        try? await Task.sleep(for: .milliseconds(15))
        if let up = key(.keyUp, s, window) { view.keyUp(with: up) }
        if wait { return await settle(view) }
        return true
    }

    /// Waits until the page has taken every key sent to it in this action, at most `within`;
    /// answers whether it did.
    @discardableResult
    static func settle(_ view: WKWebView, within: Duration = stepLimit) async -> Bool {
        guard let signal = signals[ObjectIdentifier(view)] else { return false }
        let end = ContinuousClock.now + within
        while signal.count("key") < signal.sentKeys {
            if ContinuousClock.now >= end { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// A new action starts counting keys from what the page took so far: a key-up that never
    /// came (a page that went away mid-key) doesn't hold later actions up (security review
    /// 2026-11-25).
    static func begin(_ view: WKWebView) { signals[ObjectIdentifier(view)]?.restart() }

    /// Text no key of a US keyboard types (é, an emoji), as the Character Viewer gives it: input
    /// without a key (FR-480). It doesn't wait in line with the keys, so the keys before it are
    /// taken first ("Café" came out "Caéf" on a busy Mac, 2026-11-25).
    static func insert(_ text: String, in view: WKWebView) async {
        await settle(view)
        signals[ObjectIdentifier(view)]?.clearTarget()
        let before = await count(view, "input")
        // The responder's insertText, which the view takes as an input method's text.
        view.insertText(text)
        await wait(view, "input", after: before)
    }

    /// Types `text` into what has the focus, a key per character, one after the other (FR-480),
    /// and waits until the page has taken them. Answers how many characters were typed.
    static func type(_ text: String, in view: WKWebView) async -> Int {
        var n = 0
        for ch in text {
            if Task.isCancelled { break }
            if let s = stroke(for: ch) {
                await press(s, in: view, wait: false)
            } else {
                await insert(String(ch), in: view)
            }
            n += 1
        }
        await settle(view)
        return n
    }

    // MARK: waiting

    /// Each page's `InputSignal`, by its view (registered by `LockedBrowser`).
    private static var signals: [ObjectIdentifier: InputSignal] = [:]
    static func register(_ signal: InputSignal, for view: WKWebView) { signals[ObjectIdentifier(view)] = signal }
    static func unregister(_ view: WKWebView) { signals[ObjectIdentifier(view)] = nil }

    /// How many of `name` ("up", "key", "input") the page has taken so far.
    static func count(_ view: WKWebView, _ name: String) async -> Int {
        signals[ObjectIdentifier(view)]?.count(name) ?? 0
    }

    /// Runs `code` in the input world, at most `within` (Constitution II: a page held on a
    /// dialog never answers).
    static func evaluate(_ view: WKWebView, _ code: String, within: Duration = .seconds(5)) async -> String? {
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

    /// Waits until the page has taken more of `name` than `before`, at most `stepLimit` (FR-485),
    /// looking at what it told Latchkey (no script runs in the page). A page that never gets the
    /// event (a disabled button takes none) costs that wait once.
    static func wait(_ view: WKWebView, _ name: String, after before: Int) async {
        guard let signal = signals[ObjectIdentifier(view)] else { return }
        let end = ContinuousClock.now + stepLimit
        while ContinuousClock.now < end, signal.count(name) <= before {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Where the last character went: the element's reference ("-" for one without) and the
    /// host of the frame it is in, as the frame's own address says (WebKit's, not the page's
    /// word); nil before any (spec 013 FR-1377).
    static func lastTarget(_ view: WKWebView) async -> (ref: String, host: String, type: String)? {
        signals[ObjectIdentifier(view)]?.target
    }

    /// Whether the page took the last key (its keydown was cancelled).
    static func lastKeyTaken(_ view: WKWebView) async -> Bool {
        signals[ObjectIdentifier(view)]?.lastTaken ?? false
    }
}

/// What a page's input world told Latchkey (`RealInput.counter`): the trusted events taken, where
/// the last character went, and whether the page took the last key. Only that world can post
/// here (the handler is added to it alone), and anything not of the expected shape is dropped.
@MainActor
final class InputSignal {
    private var counts: [String: Int] = [:]
    private(set) var target: (ref: String, host: String, type: String)?
    /// Keys sent to the page (`RealInput.press`), to wait until it took them all.
    var sentKeys = 0

    func clearTarget() { target = nil }
    func restart() { sentKeys = count("key") }
    private(set) var lastTaken = false

    func count(_ name: String) -> Int { counts[name] ?? 0 }

    func received(_ body: Any, host: String) {
        guard let o = body as? [String: Any], let k = o["k"] as? String else { return }
        switch k {
        case "up", "input":
            counts[k, default: 0] += 1
        case "key":
            counts[k, default: 0] += 1
            lastTaken = (o["p"] as? Bool) == true
        case "target":
            if let t = o["t"] as? String {
                target = (String(t.prefix(64)), host, String(((o["y"] as? String) ?? "").prefix(32)).lowercased())
            }
        default:
            return
        }
    }

    final class Handler: NSObject, WKScriptMessageHandler {
        weak var signal: InputSignal?
        init(_ signal: InputSignal) { self.signal = signal }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                signal?.received(message.body, host: message.frameInfo.securityOrigin.host.lowercased())
            }
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
