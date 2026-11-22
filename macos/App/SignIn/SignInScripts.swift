import Foundation

/// The page scripts of signing in (spec 013 FR-1371, FR-1372, FR-1311; plan D6). They run in the
/// page's main frame only (never in a frame from another site), check the page's own address
/// before typing, and answer "ok", a tab, and JSON, as the browser actions do. Every value is
/// spliced with `literal()`. They type only into the field Claude named; what the page means is
/// Claude's to read (Toni, 2026-11-22: "Fill-only tool").
extension PageScripts {
    /// Nothing but the answer: for the browser's own record of the page's address (FR-1328).
    static let signInHere = "'ok\\t{}'"

    /// The host to type on, when the browser's address is one `login` fills on (FR-1321): its
    /// registered site, or for a site that is itself a public suffix, only its own host.
    static func fillHost(_ login: SavedSignIn, address: String) -> String? {
        guard SiteMatch.fills(site: login.site, on: address), var host = URL(string: address)?.host()?.lowercased()
        else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !PublicSuffix.isSuffix(login.site) || host == login.site else { return nil }
        return host
    }

    /// The page with `secret` blanked out of its text, title, address, and controls (security
    /// review 2026-11-22: a page that shows what was typed must not show it to Claude).
    static func redacted(_ p: Page, _ secret: String) -> Page {
        guard secret.count >= 4 else { return p }
        let forms = Set([secret, secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? secret])
        func blank(_ s: String) -> String { forms.reduce(s) { $0.replacingOccurrences(of: $1, with: "•••") } }
        var r = p
        r.title = blank(p.title)
        r.url = blank(p.url)
        r.text = blank(p.text)
        r.elements = p.elements.map { e in
            var x = e
            x.label = blank(e.label)
            x.href = e.href.map(blank)
            x.value = e.value.map(blank)
            return x
        }
        return r
    }

    /// Types `value` into the field `ref`, as `kind` allows (FR-1372): "password" only into a
    /// password field that isn't a one-character box; "user" only into a text, email, or phone
    /// field; "code" into a text, number, phone, or password field, or, from a one-character box
    /// (or the first of a row of alike fields, United's six, 2026-11-21), across it and the boxes
    /// after it, one character each, pasted whole into the first when the boxes won't take it so.
    /// Key by key, as a keyboard does (Citi's input mask keeps nothing else, 2026-11-21). Answers
    /// `{ step: "filled", boxes }`, `{ step: "wrongsite" }`, `{ step: "notfield", is }` (what the
    /// field is), or `{ step: "unheld" }` (the page changed what was typed); "missing" when there
    /// is no such field.
    static func fillField(ref: String, kind: String, value: String, host: String) -> String {
        // nosemgrep: latchkey-page-script-literal -- besides literal() and find(), nothing.
        """
        (function (host, kind, value) {
          if (location.protocol !== 'https:' || location.hostname !== host) return 'ok\\t' + JSON.stringify({ step: 'wrongsite' });
          \(find(ref))
          function seen(x) {
            if (!x || x.disabled || x.readOnly) return false;
            var st = getComputedStyle(x);
            if (st.visibility === 'hidden' || st.display === 'none') return false;
            return !!(x.offsetWidth || x.offsetHeight || x.getClientRects().length);
          }
          var type = e.tagName === 'INPUT' ? (e.getAttribute('type') || 'text').toLowerCase() : e.tagName.toLowerCase();
          function no() { return 'ok\\t' + JSON.stringify({ step: 'notfield', is: type + (e.maxLength === 1 ? ' box' : '') }); }
          if (e.tagName !== 'INPUT' || !seen(e)) return no();
          if (kind === 'password' && (type !== 'password' || e.maxLength === 1)) return no();
          if (kind === 'user' && ['text', 'email', 'tel'].indexOf(type) < 0) return no();
          if (kind === 'code' && ['text', 'number', 'tel', 'password'].indexOf(type) < 0) return no();
          // A code only into a field that is one (security review 2026-11-22: typed into a search
          // box, a code could come back as page text Claude reads): a password field, a box for
          // one character, or a field marked or named for a code.
          function codeField(x) {
            var t = (x.getAttribute('type') || 'text').toLowerCase();
            if (['text', 'number', 'tel', 'password'].indexOf(t) < 0) return false;
            if (t === 'password' || x.maxLength === 1) return true;
            var l = '';
            try { if (x.labels && x.labels.length) l = x.labels[0].innerText || ''; } catch (y) {}
            var words = [x.name, x.id, x.className, x.getAttribute('placeholder'), x.getAttribute('aria-label'), x.getAttribute('autocomplete'), x.getAttribute('inputmode'), l].join(' ');
            return /(one-time-code|numeric|\\bcode|otp|one.?time|verif|passcode|\\bpin\\b|digit|2fa|mfa|two.?factor|token|security)/i.test(words);
          }
          if (kind === 'code' && !codeField(e)) {
            return 'ok\\t' + JSON.stringify({ step: 'notfield', is: type + ' (not a code)' });
          }
          var filled = window.__latchkeyFilled;
          if (!filled) {
            filled = [];
            try { Object.defineProperty(window, '__latchkeyFilled', { value: filled, enumerable: false }); } catch (x) {}
          }
          var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          // A browser of Latchkey's own is hidden, so focus() fires no focus event; code widgets
          // that track the active box by focus events (United's, 2026-11-21) get them sent here.
          function focusOn(x) {
            if (x.focus) x.focus();
            x.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
            x.dispatchEvent(new FocusEvent('focus'));
          }
          function same(a, b) {
            var squash = function (t) { return String(t).replace(/[\\s.\\-()]/g, '').toLowerCase(); };
            return squash(a) === squash(b);
          }
          // The focused element, also inside shadow roots.
          function focused() { var a = document.activeElement; while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement; return a; }
          function put(x, v, follow) {
            focusOn(x);
            filled.push(x);
            var start = x;
            // Emptied only when it holds something: a delete in an empty box is Backspace into
            // the box before (United left its first box empty, 2026-11-21).
            if (x.value) {
              setter.call(x, '');
              x.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
            }
            for (var i = 0; i < v.length; i++) {
              // A code widget that moves the focus to its next box after each character (Uber's,
              // 2026-11-22) gets the next one there, as a keyboard would: only another seen
              // code field after this one (the page moves the focus), never anywhere else.
              if (follow && i > 0) {
                var f = focused();
                if (f && f !== x && f.tagName === 'INPUT' && seen(f) && codeField(f) && (x.compareDocumentPosition(f) & Node.DOCUMENT_POSITION_FOLLOWING)) { x = f; filled.push(x); }
              }
              var ch = v.charAt(i), up = ch.toUpperCase();
              var code = /[a-z]/i.test(ch) ? 'Key' + up : (/[0-9]/.test(ch) ? 'Digit' + ch : '');
              var kc = /[a-z0-9]/i.test(ch) ? up.charCodeAt(0) : 0;
              var go = x.dispatchEvent(new KeyboardEvent('keydown', { key: ch, code: code, keyCode: kc, which: kc, bubbles: true, cancelable: true }));
              go = x.dispatchEvent(new KeyboardEvent('keypress', { key: ch, code: code, keyCode: ch.charCodeAt(0), charCode: ch.charCodeAt(0), which: ch.charCodeAt(0), bubbles: true, cancelable: true })) && go;
              go = x.dispatchEvent(new InputEvent('beforeinput', { data: ch, inputType: 'insertText', bubbles: true, cancelable: true })) && go;
              if (go) {
                var was = x.value, s = x.selectionStart, t = x.selectionEnd;
                if (s === null || s === undefined) { s = was.length; t = was.length; }
                setter.call(x, was.slice(0, s) + ch + was.slice(t));
                try { x.setSelectionRange(s + 1, s + 1); } catch (y) {}
                x.dispatchEvent(new InputEvent('input', { data: ch, inputType: 'insertText', bubbles: true }));
              }
              x.dispatchEvent(new KeyboardEvent('keyup', { key: ch, code: code, keyCode: kc, which: kc, bubbles: true }));
            }
            x.dispatchEvent(new Event('change', { bubbles: true }));
            if (x.blur) x.blur();
            return x === start && same(x.value, v);
          }
          var done = 'ok\\t' + JSON.stringify({ step: 'filled', boxes: 0 });
          var unheld = 'ok\\t' + JSON.stringify({ step: 'unheld' });
          if (kind !== 'code') return put(e, value) ? done : unheld;
          // The boxes, when the field is one: it and the boxes after it, in the page's order.
          var inputs = __lkAll('input').filter(seen);
          var from = inputs.indexOf(e), boxes = [];
          // Boxes named "1 of 4" to "4 of 4" (Uber's, 2026-11-22: each in a wrapper of its own).
          var nth = function (x) { var m = /\\b(\\d+) of (\\d+)\\b/.exec(x.getAttribute('aria-label') || ''); return m ? [+m[1], +m[2]] : null; };
          var own = nth(e);
          if (e.maxLength === 1) {
            boxes = inputs.slice(from).filter(function (x) { return x.maxLength === 1; }).slice(0, value.length);
          } else if (own && own[0] === 1 && own[1] === value.length) {
            boxes = inputs.slice(from, from + value.length).filter(function (x, i) { var n = nth(x); return n && n[0] === i + 1 && n[1] === own[1]; });
            if (boxes.length !== value.length) boxes = [];
          } else if (e.className) {
            var alike = inputs.slice(from).filter(function (x) {
              return x.className === e.className && x.parentElement && e.parentElement
                && x.parentElement.className === e.parentElement.className;
            });
            if (alike.length === value.length && value.length >= 4 && value.length <= 8) boxes = alike;
          }
          if (!boxes.length) {
            if (put(e, value, true)) return done;
            // The page spread the code over the boxes after this one itself: held all the same.
            var row = inputs.slice(from, from + value.length);
            if (row.length > 1 && same(row.map(function (b) { return b.value; }).join(''), value)) {
              row.forEach(function (b) { if (filled.indexOf(b) < 0) filled.push(b); });
              return 'ok\\t' + JSON.stringify({ step: 'filled', boxes: row.length });
            }
            return unheld;
          }
          if (boxes.length < value.length) return 'ok\\t' + JSON.stringify({ step: 'notfield', is: boxes.length + ' boxes for a ' + value.length + '-character code' });
          boxes.forEach(function (b, i) { put(b, value.charAt(i)); });
          var held = function () { return boxes.map(function (b) { return b.value; }).join(''); };
          if (!same(held(), value)) {
            // Else the whole code pasted into the first box, as password managers do.
            boxes.forEach(function (b) { if (b.value) { focusOn(b); setter.call(b, ''); b.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' })); } });
            var first = boxes[0];
            focusOn(first);
            var data = null;
            try { data = new DataTransfer(); data.setData('text/plain', value); } catch (y) {}
            if (first.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }))) {
              first.dispatchEvent(new InputEvent('beforeinput', { data: value, inputType: 'insertFromPaste', bubbles: true, cancelable: true }));
              setter.call(first, value);
              first.dispatchEvent(new InputEvent('input', { data: value, inputType: 'insertFromPaste', bubbles: true }));
            }
          }
          if (!same(held(), value)) return unheld;
          return 'ok\\t' + JSON.stringify({ step: 'filled', boxes: boxes.length });
        })(\(literal(host)), \(literal(kind)), \(literal(value)))
        """
    }

    /// Empties every password field on the page and every field Latchkey filled that is still
    /// there, so no script can read them afterwards (FR-1311). Answers `{ cleared }`.
    static let clearSignIn = """
        (function () {
          \(PageScripts.deep)
          var n = 0, setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          var all = __lkAll('input[type="password"]').concat(window.__latchkeyFilled || []);
          all.forEach(function (e) {
            if (e && e.isConnected && e.value && e.type !== 'email' && !/(^|\\s)(username|email)(\\s|$)/i.test(e.getAttribute('autocomplete') || '')) {
              setter.call(e, ''); n++;
            }
          });
          if (window.__latchkeyFilled) window.__latchkeyFilled.length = 0;
          return 'ok\\t' + JSON.stringify({ cleared: n });
        })()
        """
}
