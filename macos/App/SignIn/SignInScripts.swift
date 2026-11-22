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
          function put(x, v) {
            focusOn(x);
            filled.push(x);
            // Emptied only when it holds something: a delete in an empty box is Backspace into
            // the box before (United left its first box empty, 2026-11-21).
            if (x.value) {
              setter.call(x, '');
              x.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
            }
            for (var i = 0; i < v.length; i++) {
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
            return same(x.value, v);
          }
          var done = 'ok\\t' + JSON.stringify({ step: 'filled', boxes: 0 });
          var unheld = 'ok\\t' + JSON.stringify({ step: 'unheld' });
          if (kind !== 'code') return put(e, value) ? done : unheld;
          // The boxes, when the field is one: it and the boxes after it, in the page's order.
          var inputs = Array.prototype.filter.call(document.querySelectorAll('input'), seen);
          var from = inputs.indexOf(e), boxes = [];
          if (e.maxLength === 1) {
            boxes = inputs.slice(from).filter(function (x) { return x.maxLength === 1; }).slice(0, value.length);
          } else if (e.className) {
            var alike = inputs.slice(from).filter(function (x) {
              return x.className === e.className && x.parentElement && e.parentElement
                && x.parentElement.className === e.parentElement.className;
            });
            if (alike.length === value.length && value.length >= 4 && value.length <= 8) boxes = alike;
          }
          if (!boxes.length) return put(e, value) ? done : unheld;
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
          var n = 0, setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          var all = Array.prototype.slice.call(document.querySelectorAll('input[type="password"]')).concat(window.__latchkeyFilled || []);
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
