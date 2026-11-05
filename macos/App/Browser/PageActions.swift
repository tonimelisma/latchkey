import Foundation

/// The page scripts of the actions added on 2026-11-04 (spec 005 FR-433 to FR-440): keys, hover,
/// scrolling, choosing from lists, attaching files, saving a file, and the copy of the page a
/// picture is drawn from. All of them run inside the page, as click and type do, so they work in
/// a background tab, with the Mac locked while Safari answers, and in Latchkey's own browser
/// (research.md, "Keys, hover, scrolling, files, and pictures"). Each takes its values as one
/// JSON text, spliced in with `literal(...)` only, and parsed in the page.
extension PageScripts {
    /// The element a reference names, or the page's focused element (or body) without one.
    /// Answers 'missing' when a reference names nothing.
    private static let target = """
        var e = a.ref ? document.querySelector('[data-latchkey=' + JSON.stringify(String(a.ref)) + ']') : (document.activeElement || document.body);
        if (!e) return 'missing';
        """

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return literal(String(decoding: data, as: UTF8.self))
    }

    // MARK: keys

    /// A key, or a shortcut, as Claude names it: "Enter", "Escape", "Tab", "ArrowDown", "a",
    /// "cmd+a", "shift+Tab".
    struct Key: Equatable, Sendable {
        var key: String
        var code: String
        var keyCode: Int
        var shift = false
        var ctrl = false
        var alt = false
        var meta = false

        struct Unknown: Error { var name: String }

        /// Claude's names for keys, as the page's `KeyboardEvent.key` spells them.
        static let names: [String: (String, String, Int)] = [
            "enter": ("Enter", "Enter", 13), "return": ("Enter", "Enter", 13), "escape": ("Escape", "Escape", 27),
            "esc": ("Escape", "Escape", 27), "tab": ("Tab", "Tab", 9), "backspace": ("Backspace", "Backspace", 8),
            "delete": ("Delete", "Delete", 46), "space": (" ", "Space", 32), "arrowup": ("ArrowUp", "ArrowUp", 38),
            "up": ("ArrowUp", "ArrowUp", 38), "arrowdown": ("ArrowDown", "ArrowDown", 40),
            "down": ("ArrowDown", "ArrowDown", 40), "arrowleft": ("ArrowLeft", "ArrowLeft", 37),
            "left": ("ArrowLeft", "ArrowLeft", 37), "arrowright": ("ArrowRight", "ArrowRight", 39),
            "right": ("ArrowRight", "ArrowRight", 39), "home": ("Home", "Home", 36), "end": ("End", "End", 35),
            "pageup": ("PageUp", "PageUp", 33), "pagedown": ("PageDown", "PageDown", 34),
        ]

        init(key: String, code: String, keyCode: Int) {
            self.key = key
            self.code = code
            self.keyCode = keyCode
        }

        init(_ name: String) throws {
            let parts = name.split(separator: "+", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // "cmd++" means the + key.
            var names = parts
            if name.hasSuffix("++") { names = Array(parts.dropLast(2)) + ["+"] }
            guard let last = names.last, !last.isEmpty else { throw Unknown(name: name) }
            if let k = Self.names[last.lowercased().replacingOccurrences(of: "_", with: "")] {
                self.init(key: k.0, code: k.1, keyCode: k.2)
            } else if last.count == 1, let ch = last.first {
                let upper = ch.uppercased()
                let code = ch.isLetter ? "Key" + upper : ch.isNumber ? "Digit" + String(ch) : ""
                self.init(key: String(ch), code: code, keyCode: Int(upper.unicodeScalars.first?.value ?? 0))
            } else {
                throw Unknown(name: name)
            }
            for m in names.dropLast() {
                switch m.lowercased() {
                case "shift": shift = true
                case "ctrl", "control": ctrl = true
                case "alt", "option", "opt": alt = true
                case "cmd", "command", "meta": meta = true
                default: throw Unknown(name: name)
                }
            }
            if shift, key.count == 1 { key = key.uppercased() }
        }
    }

    /// Presses `keys` one after the other in the element `ref` names (focused first), or in the
    /// focused element. The page gets keydown, keypress for characters, and keyup, as from a
    /// keyboard; where the page doesn't take a key itself (`preventDefault`), the script does what
    /// the browser would: Enter submits a field's form or clicks a button or link, Tab moves the
    /// focus, a character or Backspace edits a field, arrows change a list's choice, and keys that
    /// scroll scroll. Answers "ok" and, on a second line, JSON: what each key did.
    static func keys(_ keys: [Key], ref: String?) -> String {
        let list: [[String: Any]] = keys.map {
            [
                "key": $0.key, "code": $0.code, "keyCode": $0.keyCode, "shift": $0.shift, "ctrl": $0.ctrl,
                "alt": $0.alt, "meta": $0.meta,
            ]
        }
        var args: [String: Any] = ["keys": list]
        if let ref { args["ref"] = ref }
        return """
            (function (a) { \(target)
              if (a.ref && e.focus) e.focus();
              var did = [];
              function focusables() {
                return Array.prototype.filter.call(document.querySelectorAll('a[href], button, input:not([type=hidden]), select, textarea, [tabindex], [contenteditable=true], summary'), function (x) {
                  if (x.disabled || x.tabIndex < 0) return false;
                  var r = x.getBoundingClientRect(), st = getComputedStyle(x);
                  return st.display !== 'none' && st.visibility !== 'hidden' && (r.width > 0 || r.height > 0);
                });
              }
              function editable(x) {
                if (!x) return false;
                if (x.isContentEditable) return true;
                if (x.tagName === 'TEXTAREA') return !x.readOnly && !x.disabled;
                if (x.tagName !== 'INPUT') return false;
                var t = (x.type || 'text').toLowerCase();
                return !x.readOnly && !x.disabled && ['text', 'search', 'email', 'url', 'tel', 'password', 'number', ''].indexOf(t) >= 0;
              }
              function setValue(x, v) {
                var proto = x.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                Object.getOwnPropertyDescriptor(proto, 'value').set.call(x, v);
              }
              function insert(x, text, back) {
                if (x.isContentEditable) {
                  var s = getSelection();
                  if (back) { if (s && s.rangeCount && !s.isCollapsed) s.deleteFromDocument(); else document.execCommand('delete'); }
                  else document.execCommand('insertText', false, text);
                  return;
                }
                var v = String(x.value || ''), st = 0, en = v.length;
                try { if (x.selectionStart !== null) { st = x.selectionStart; en = x.selectionEnd; } } catch (z) {}
                if (back) { if (st === en && st > 0) st -= 1; text = ''; }
                x.dispatchEvent(new InputEvent('beforeinput', { bubbles: true, cancelable: true, inputType: back ? 'deleteContentBackward' : 'insertText', data: back ? null : text }));
                setValue(x, v.slice(0, st) + text + v.slice(en));
                try { x.setSelectionRange(st + text.length, st + text.length); } catch (z) {}
                x.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: back ? 'deleteContentBackward' : 'insertText', data: back ? null : text }));
              }
              function scroller(x) {
                for (var n = x; n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
                  var o = getComputedStyle(n).overflowY;
                  if ((o === 'auto' || o === 'scroll') && n.scrollHeight > n.clientHeight) return n;
                }
                return document.scrollingElement || document.documentElement;
              }
              a.keys.forEach(function (k) {
                var t = document.activeElement || document.body;
                var init = { key: k.key, code: k.code, keyCode: k.keyCode, which: k.keyCode, shiftKey: k.shift, ctrlKey: k.ctrl, altKey: k.alt, metaKey: k.meta, bubbles: true, cancelable: true, composed: true };
                var name = (k.meta ? 'cmd+' : '') + (k.ctrl ? 'ctrl+' : '') + (k.alt ? 'alt+' : '') + (k.shift ? 'shift+' : '') + k.key;
                var down = t.dispatchEvent(new KeyboardEvent('keydown', init));
                var ch = k.key.length === 1 && !k.meta && !k.ctrl;
                if (down && ch) down = t.dispatchEvent(new KeyboardEvent('keypress', init));
                var what = 'the page took it';
                if (down) {
                  what = 'nothing more';
                  var tag = t.tagName, type = (t.type || '').toLowerCase();
                  if (ch && editable(t)) { insert(t, k.key, false); what = 'typed'; }
                  else if (k.key === 'Backspace' && editable(t)) { insert(t, '', true); what = 'deleted a character'; }
                  else if ((k.meta || k.ctrl) && k.key.toLowerCase() === 'a' && editable(t)) { if (t.select) t.select(); else document.execCommand('selectAll'); what = 'selected all'; }
                  else if (k.key === 'Enter' && tag === 'INPUT' && t.form && ['checkbox', 'radio', 'file', 'button', 'submit', 'reset'].indexOf(type) < 0) {
                    if (t.form.requestSubmit) t.form.requestSubmit(); else t.form.submit();
                    what = 'sent the form';
                  }
                  else if ((k.key === 'Enter' && (tag === 'BUTTON' || tag === 'A' || tag === 'SUMMARY' || (tag === 'INPUT' && ['button', 'submit', 'reset', 'checkbox', 'radio'].indexOf(type) >= 0) || t.getAttribute('role') === 'button' || t.getAttribute('role') === 'link')) || (k.key === ' ' && (tag === 'BUTTON' || (tag === 'INPUT' && ['button', 'submit', 'checkbox', 'radio'].indexOf(type) >= 0)))) { t.click(); what = 'clicked ' + tag.toLowerCase(); }
                  else if (k.key === 'Tab') {
                    var f = focusables(), i = f.indexOf(t), n = f.length ? f[(i + (k.shift ? -1 : 1) + f.length + (i < 0 && k.shift ? 1 : 0)) % f.length] : null;
                    if (n && n.focus) { n.focus(); what = 'moved the focus to ' + (n.getAttribute('data-latchkey') || n.tagName.toLowerCase()); }
                  }
                  else if (tag === 'SELECT' && /^Arrow(Up|Down)$|^Home$|^End$/.test(k.key) && t.options.length) {
                    var j = t.selectedIndex, m = t.options.length - 1;
                    j = k.key === 'ArrowUp' ? Math.max(j - 1, 0) : k.key === 'ArrowDown' ? Math.min(j + 1, m) : k.key === 'Home' ? 0 : m;
                    if (j !== t.selectedIndex) { t.selectedIndex = j; t.dispatchEvent(new Event('input', { bubbles: true })); t.dispatchEvent(new Event('change', { bubbles: true })); }
                    what = 'chose ' + t.options[t.selectedIndex].text.trim().slice(0, 80);
                  }
                  else if (!editable(t) && /^(ArrowUp|ArrowDown|ArrowLeft|ArrowRight|PageUp|PageDown|Home|End| )$/.test(k.key)) {
                    var s = scroller(t), h = s === document.scrollingElement || s === document.documentElement ? innerHeight : s.clientHeight;
                    var dy = { ArrowUp: -40, ArrowDown: 40, PageUp: -h * 0.9, PageDown: h * 0.9, ' ': (k.shift ? -1 : 1) * h * 0.9 }[k.key];
                    if (k.key === 'Home') s.scrollTop = 0; else if (k.key === 'End') s.scrollTop = s.scrollHeight;
                    else if (k.key === 'ArrowLeft' || k.key === 'ArrowRight') s.scrollLeft += k.key === 'ArrowLeft' ? -40 : 40;
                    else s.scrollTop += dy;
                    what = 'scrolled';
                  }
                }
                t.dispatchEvent(new KeyboardEvent('keyup', init));
                did.push(name + ': ' + what);
              });
              return 'ok\\t' + JSON.stringify(did);
            })(JSON.parse(\(json(args))))
            """
    }

    // MARK: hover

    /// Moves a pretend pointer onto the element: pointerover, pointerenter, mouseover,
    /// mouseenter, pointermove, and mousemove at its middle, as a mouse would. A style that
    /// applies only under a real pointer (CSS `:hover`) can't be set from a script; the answer
    /// counts what became visible.
    static func hover(_ ref: String) -> String {
        """
        (function (a) { \(target)
          if (e.scrollIntoView) e.scrollIntoView({ block: 'center' });
          function visible() { var n = 0; document.querySelectorAll('body *').forEach(function (x) { if (x.getClientRects().length) n++; }); return n; }
          var before = visible(), r = e.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
          var o = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, view: window };
          var p = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, pointerType: 'mouse', isPrimary: true, view: window };
          var leaf = document.elementFromPoint(x, y);
          var on = leaf && e.contains(leaf) ? leaf : e;
          var path = []; for (var n = on; n; n = n.parentElement) path.unshift(n);
          on.dispatchEvent(new PointerEvent('pointerover', p));
          path.forEach(function (n) { n.dispatchEvent(new PointerEvent('pointerenter', Object.assign({}, p, { bubbles: false }))); });
          on.dispatchEvent(new MouseEvent('mouseover', o));
          path.forEach(function (n) { n.dispatchEvent(new MouseEvent('mouseenter', Object.assign({}, o, { bubbles: false }))); });
          on.dispatchEvent(new PointerEvent('pointermove', p));
          on.dispatchEvent(new MouseEvent('mousemove', o));
          return 'ok\\t' + JSON.stringify(Math.max(visible() - before, 0));
        })(JSON.parse(\(json(["ref": ref]))))
        """
    }

    // MARK: scrolling

    /// Scrolls the page, or the element `ref` names (its nearest part that scrolls), by
    /// `direction` (down, up, left, right: `amount` pixels, or 90% of what shows; top, bottom:
    /// all the way). A wheel event goes first, for pages that scroll themselves (maps, carousels);
    /// unless the page takes it, the script scrolls. Answers "ok" and, on a second line, JSON:
    /// the position, the most it can be, and the part showing.
    static func scroll(_ ref: String?, direction: String, amount: Int?) -> String {
        var args: [String: Any] = ["dir": direction]
        if let ref { args["ref"] = ref }
        if let amount { args["amount"] = amount }
        return """
            (function (a) {
              var e = null;
              if (a.ref) { e = document.querySelector('[data-latchkey=' + JSON.stringify(String(a.ref)) + ']'); if (!e) return 'missing'; }
              var page = document.scrollingElement || document.documentElement, s = page;
              for (var n = e; n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
                var st = getComputedStyle(n);
                if ((/(auto|scroll)/.test(st.overflowY) && n.scrollHeight > n.clientHeight) || (/(auto|scroll)/.test(st.overflowX) && n.scrollWidth > n.clientWidth)) { s = n; break; }
              }
              var whole = s === page, h = whole ? innerHeight : s.clientHeight, w = whole ? innerWidth : s.clientWidth;
              var step = a.amount > 0 ? a.amount : null, dx = 0, dy = 0;
              switch (a.dir) {
                case 'down': dy = step || h * 0.9; break;
                case 'up': dy = -(step || h * 0.9); break;
                case 'right': dx = step || w * 0.9; break;
                case 'left': dx = -(step || w * 0.9); break;
                case 'top': dy = -s.scrollHeight; break;
                case 'bottom': dy = s.scrollHeight; break;
              }
              var on = e || document.elementFromPoint(innerWidth / 2, innerHeight / 2) || document.body;
              var took = !on.dispatchEvent(new WheelEvent('wheel', { deltaX: dx, deltaY: dy, deltaMode: 0, bubbles: true, cancelable: true, composed: true, clientX: innerWidth / 2, clientY: innerHeight / 2 }));
              var x0 = s.scrollLeft, y0 = s.scrollTop;
              if (!took) {
                if (a.dir === 'top') s.scrollTop = 0; else if (a.dir === 'bottom') s.scrollTop = s.scrollHeight;
                else { s.scrollLeft = x0 + dx; s.scrollTop = y0 + dy; }
              }
              return 'ok\\t' + JSON.stringify({ x: Math.round(s.scrollLeft), y: Math.round(s.scrollTop), maxX: Math.max(0, s.scrollWidth - (whole ? innerWidth : s.clientWidth)), maxY: Math.max(0, s.scrollHeight - h), height: Math.round(h), element: !whole, pageTook: took, moved: s.scrollLeft !== x0 || s.scrollTop !== y0 });
            })(JSON.parse(\(json(args))))
            """
    }

    /// Where a scroll left the page, as the scroll script answers it.
    struct ScrollPosition: Decodable, Equatable, Sendable {
        var x: Int
        var y: Int
        var maxX: Int
        var maxY: Int
        var height: Int
        var element: Bool
        var pageTook: Bool
        var moved: Bool

        var said: String {
            let whereTo =
                maxY <= 0
                ? "it doesn't scroll up or down" : y <= 0 ? "at the top" : y >= maxY ? "at the bottom" : "\(y) of \(maxY) pixels down"
            let part = element ? "The part of the page" : "The page"
            let note = pageTook ? " The page handled the scroll itself." : moved ? "" : " Nothing moved."
            return "\(part) is \(whereTo) (\(height) pixels show at a time).\(note)"
        }
    }

    // MARK: lists

    /// Chooses options in a list (`select`, also one that takes several) by their text or value,
    /// or an item of a list the page builds itself (role listbox, menu, or combobox: the item whose
    /// text matches is clicked). Answers "ok" and the chosen texts (JSON) on a second line, or
    /// "nooption" and, on a second line, the texts there are (JSON, at most 50).
    static func choose(_ ref: String, options: [String]) -> String {
        """
        (function (a) { \(target)
          function clean(s) { return String(s || '').replace(/\\s+/g, ' ').trim(); }
          function matches(o, want) { return clean(o.text || o.textContent) === clean(want) || o.value === want || clean(o.label) === clean(want); }
          if (e.tagName === 'SELECT') {
            var picked = [], missing = [];
            a.options.forEach(function (want) {
              var o = Array.prototype.find.call(e.options, function (o) { return matches(o, want); });
              if (o && !o.disabled) picked.push(o); else missing.push(want);
            });
            if (missing.length || !picked.length) return 'nooption\\t' + JSON.stringify(Array.prototype.slice.call(e.options, 0, 50).map(function (o) { return clean(o.text); }));
            if (e.focus) e.focus();
            if (e.multiple) Array.prototype.forEach.call(e.options, function (o) { o.selected = picked.indexOf(o) >= 0; });
            else e.value = picked[picked.length - 1].value;
            e.dispatchEvent(new Event('input', { bubbles: true }));
            e.dispatchEvent(new Event('change', { bubbles: true }));
            return 'ok\\t' + JSON.stringify(Array.prototype.filter.call(e.options, function (o) { return o.selected; }).map(function (o) { return clean(o.text); }));
          }
          // A list the page builds itself: open it, then click the item.
          var owner = e.getAttribute('aria-controls') || e.getAttribute('aria-owns');
          if (e.click && (e.getAttribute('role') === 'combobox' || e.getAttribute('aria-haspopup'))) e.click();
          var scope = (owner && document.getElementById(owner)) || (e.querySelector('[role=option],[role=menuitem],[role=menuitemradio],[role=menuitemcheckbox],li') ? e : document);
          var items = Array.prototype.slice.call(scope.querySelectorAll('[role=option],[role=menuitem],[role=menuitemradio],[role=menuitemcheckbox]' + (scope === e ? ',li' : '')));
          var done = [];
          for (var i = 0; i < a.options.length; i++) {
            var it = items.find(function (x) { return clean(x.textContent) === clean(a.options[i]) || x.getAttribute('data-value') === a.options[i]; });
            if (!it) return 'nooption\\t' + JSON.stringify(items.slice(0, 50).map(function (x) { return clean(x.textContent).slice(0, 80); }));
            if (it.scrollIntoView) it.scrollIntoView({ block: 'nearest' });
            ['pointerdown', 'mousedown', 'pointerup', 'mouseup'].forEach(function (t) { it.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, view: window })); });
            it.click();
            done.push(clean(it.textContent).slice(0, 80));
          }
          return 'ok\\t' + JSON.stringify(done);
        })(JSON.parse(\(json(["ref": ref, "options": options]))))
        """
    }

    // MARK: files into the page

    /// A file to attach, as the page gets it.
    struct Attachment: Sendable, Equatable {
        var name: String
        var type: String
        var data: Data
    }

    /// Attaches `files` to the file field `ref` names (its `files` set as a picked file would be,
    /// then input and change), or drops them on an element that takes dropped files (dragenter,
    /// dragover, drop, with the files). The files are built in the page from their bytes
    /// (base64). Answers "ok" and, on a second line, JSON: "field" or "dropped", and the count the
    /// field now holds; "notfile" for an element that is neither; "single" when a field takes
    /// one file and more were given.
    static func attach(_ ref: String, files: [Attachment]) -> String {
        let list: [[String: Any]] = files.map {
            ["name": $0.name, "type": $0.type, "b64": $0.data.base64EncodedString()]
        }
        return """
            (function (a) { \(target)
              var dt = new DataTransfer();
              a.files.forEach(function (f) {
                var bin = atob(f.b64), u = new Uint8Array(bin.length);
                for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
                dt.items.add(new File([u], f.name, { type: f.type, lastModified: Date.now() }));
              });
              var input = e.tagName === 'INPUT' && (e.type || '').toLowerCase() === 'file' ? e : null;
              if (!input && e.tagName === 'LABEL' && e.control && (e.control.type || '').toLowerCase() === 'file') input = e.control;
              if (!input) { var inner = e.querySelectorAll ? e.querySelectorAll('input[type=file]') : []; if (inner.length === 1) input = inner[0]; }
              if (input) {
                if (input.disabled) return 'notfile';
                if (!input.multiple && a.files.length > 1) return 'single';
                input.files = dt.files;
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                return 'ok\\t' + JSON.stringify(['field', input.files.length]);
              }
              var r = e.getBoundingClientRect(), o = { bubbles: true, cancelable: true, composed: true, dataTransfer: dt, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
              e.dispatchEvent(new DragEvent('dragenter', o));
              var over = !e.dispatchEvent(new DragEvent('dragover', o));
              var dropped = !e.dispatchEvent(new DragEvent('drop', o));
              if (!over && !dropped) return 'notfile';
              return 'ok\\t' + JSON.stringify(['dropped', a.files.length]);
            })(JSON.parse(\(json(["ref": ref, "files": list]))))
            """
    }

    // MARK: a file out of the page

    /// Starts fetching the file a link names (`ref`), the address `url`, or, with neither, the
    /// page's own address, in the page, with the page's own cookies and session: what the
    /// page's own link would get. The result waits in the page for `takeDownload`, under a
    /// property that isn't enumerable. Answers "ok" with, on a second line, JSON: the address and
    /// the name the link suggests; "missing" for a reference that names nothing; "nolink" for an
    /// element with no address.
    static func startDownload(ref: String?, url: String?, limit: Int) -> String {
        var args: [String: Any] = ["limit": limit]
        if let ref { args["ref"] = ref }
        if let url { args["url"] = url }
        return """
            (function (a) {
              var address = a.url || location.href, suggested = '';
              if (a.ref) {
                var e = document.querySelector('[data-latchkey=' + JSON.stringify(String(a.ref)) + ']');
                if (!e) return 'missing';
                var l = e.closest ? e.closest('a[href], area[href]') : null;
                var src = l ? l.href : (e.currentSrc || e.src || e.href || (e.data && e.tagName === 'OBJECT' ? e.data : ''));
                if (!src) return 'nolink';
                address = String(src);
                if (l && l.hasAttribute('download')) suggested = l.getAttribute('download') || '';
              }
              var job = { state: 'running' };
              try { Object.defineProperty(window, '__latchkeyDownload', { value: job, configurable: true, enumerable: false }); } catch (x) { window.__latchkeyDownload = job; }
              fetch(address, { credentials: 'include' }).then(function (r) {
                job.status = r.status; job.type = r.headers.get('content-type') || ''; job.disposition = r.headers.get('content-disposition') || ''; job.final = r.url || address;
                var n = Number(r.headers.get('content-length') || 0);
                if (n > a.limit) { job.state = 'toobig'; job.size = n; throw 0; }
                return r.arrayBuffer();
              }).then(function (ab) {
                if (ab.byteLength > a.limit) { job.state = 'toobig'; job.size = ab.byteLength; return; }
                var u = new Uint8Array(ab), parts = [];
                for (var i = 0; i < u.length; i += 0x8000) parts.push(String.fromCharCode.apply(null, u.subarray(i, i + 0x8000)));
                job.b64 = btoa(parts.join('')); job.size = u.length; job.state = 'done';
              }).catch(function (x) { if (job.state === 'running') { job.state = 'failed'; job.error = String(x); } });
              return 'ok\\t' + JSON.stringify({ address: address, suggested: suggested });
            })(JSON.parse(\(json(args))))
            """
    }

    /// The fetched file once it is there (and gone from the page then), as JSON; `{"state":
    /// "running"}` while it isn't; `{"state": "none"}` when the page has no fetch of Latchkey's
    /// (it went to another page).
    static let takeDownload = """
        (function () {
          var j = window.__latchkeyDownload;
          if (!j) return JSON.stringify({ state: 'none' });
          if (j.state === 'running') return JSON.stringify({ state: 'running' });
          try { delete window.__latchkeyDownload; } catch (x) {}
          return JSON.stringify(j);
        })()
        """

    /// What `takeDownload` answers.
    struct Fetched: Decodable, Sendable {
        var state: String
        var status: Int?
        var type: String?
        var disposition: String?
        var final: String?
        var size: Int?
        var b64: String?
        var error: String?

        init(state: String, error: String? = nil) {
            self.state = state
            self.error = error
        }

        static func decode(_ json: String) throws -> Fetched {
            do { return try JSONDecoder().decode(Fetched.self, from: Data(json.utf8)) } catch {
                throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
            }
        }
    }

    /// What `startDownload` answers after "ok".
    struct DownloadStart: Decodable, Sendable {
        var address: String
        var suggested: String

        static func decode(_ json: String) throws -> DownloadStart {
            do { return try JSONDecoder().decode(DownloadStart.self, from: Data(json.utf8)) } catch {
                throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
            }
        }
    }

    // MARK: the copy a picture is drawn from

    /// The page as it is now, for a picture drawn by Latchkey's own browser when the screen
    /// can't be captured (spec 005 FR-439): the document's markup with what fields hold, what is
    /// checked and chosen, a canvas's drawing (when the page may read it), and the frames'
    /// address, without the page's scripts; plus the page's address, size, and scroll position.
    /// Answers JSON, the markup cut at `limit` characters.
    static func pictureCopy(limit: Int) -> String {
        """
        (function (a) {
          var doc = document.documentElement, copy = doc.cloneNode(true);
          var live = doc.querySelectorAll('*'), cloned = copy.querySelectorAll('*');
          for (var i = 0; i < live.length && i < cloned.length; i++) {
            var l = live[i], c = cloned[i], tag = l.tagName;
            try {
              if (tag === 'INPUT') {
                var t = (l.type || '').toLowerCase();
                if (t === 'checkbox' || t === 'radio') { if (l.checked) c.setAttribute('checked', ''); else c.removeAttribute('checked'); }
                else if (t === 'password') c.setAttribute('value', l.value ? '••••••••' : '');
                else if (t !== 'file') c.setAttribute('value', l.value);
              } else if (tag === 'TEXTAREA') { c.textContent = l.value; }
              else if (tag === 'SELECT') { for (var k = 0; k < l.options.length && k < c.options.length; k++) { if (l.options[k].selected) c.options[k].setAttribute('selected', ''); else c.options[k].removeAttribute('selected'); } }
              else if (tag === 'CANVAS') { var img = document.createElement('img'); img.src = l.toDataURL(); img.width = l.width; img.height = l.height; img.style.cssText = getComputedStyle(l).cssText; c.replaceWith(img); }
              else if (tag === 'IMG' && l.currentSrc) { c.setAttribute('src', l.currentSrc); c.removeAttribute('srcset'); c.removeAttribute('loading'); }
            } catch (x) {}
          }
          copy.querySelectorAll('script, noscript, meta[http-equiv]').forEach(function (s) { s.remove(); });
          var head = copy.querySelector('head');
          if (head) {
            var base = document.createElement('base'); base.href = document.baseURI;
            head.insertBefore(base, head.firstChild);
            var meta = document.createElement('meta'); meta.setAttribute('http-equiv', 'Content-Security-Policy'); meta.setAttribute('content', "script-src 'none'");
            head.insertBefore(meta, head.firstChild);
          }
          var html = '<!DOCTYPE html>' + copy.outerHTML;
          var s = document.scrollingElement || doc;
          return JSON.stringify({ url: location.href, title: document.title, width: innerWidth, height: innerHeight, x: s.scrollLeft, y: s.scrollTop, cut: html.length > a.limit, html: html.slice(0, a.limit) });
        })(JSON.parse(\(json(["limit": limit]))))
        """
    }

    struct PictureCopy: Decodable, Sendable {
        var url: String
        var title: String
        var width: Double
        var height: Double
        var x: Double
        var y: Double
        var cut: Bool
        var html: String

        static func decode(_ json: String) throws -> PictureCopy {
            do { return try JSONDecoder().decode(PictureCopy.self, from: Data(json.utf8)) } catch {
                throw SafariBrowser.Failure.failed("The page didn't answer as expected.")
            }
        }
    }

    /// The most of a page's markup the copy for a picture carries (characters).
    static let pictureCopyLimit = 8_000_000
}
