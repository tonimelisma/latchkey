import Foundation

/// JavaScript that runs inside the page (spec 005 plan D3). Values from Claude are JSON-encoded
/// into the script, never spliced in as code.
enum PageScripts {
    struct Page: Decodable, Sendable {
        var title: String
        var url: String
        var total: Int
        var text: String
        var elements: [Element]
    }

    struct Element: Decodable, Sendable, Equatable {
        var ref: String
        var kind: String
        var label: String
        var href: String?
        var value: String?
        var checked: Bool?
    }

    static let pageSize = ResultLimit.characters

    static func decode(_ json: String) throws -> Page {
        try JSONDecoder().decode(Page.self, from: Data(json.utf8))
    }

    static func literal(_ s: String) -> String {
        let data = (try? JSONEncoder().encode([s])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    static let stamp = "String(performance.timeOrigin) + '|' + document.readyState + '|' + location.href"

    struct Stamp: Sendable, Equatable {
        var origin: String
        var complete: Bool
        var address: String

        init(_ answer: String) {
            let parts = answer.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            origin = parts.first ?? ""
            complete = parts.count > 1 && parts[1] == "complete"
            address = parts.count > 2 ? parts[2] : ""
        }
    }

    /// Title, address, visible text from `offset`, and the visible things Claude can act on,
    /// each tagged with a reference that stays on the element. A field's current value comes
    /// along, except for fields that hold a secret (FR-410): password fields, and fields the
    /// page marks (autocomplete) as a password, a one-time code, or a card number or security
    /// code. Those say only "(hidden)" when filled in; Claude can still type into them.
    static func read(offset: Int) -> String {
        // nosemgrep: latchkey-page-script-literal -- splices in only two Ints (offset, pageSize).
        """
        (function latchkeyRead(offset, max) {
          var root = document.documentElement;
          var next = parseInt(root.getAttribute('data-latchkey-next') || '1', 10);
          var sel = 'a[href], button, input:not([type=hidden]), textarea, select, summary, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [role=option], [contenteditable=true]';
          var nodes = document.querySelectorAll(sel), out = [];
          for (var i = 0; i < nodes.length && out.length < 400; i++) {
            var e = nodes[i], r = e.getBoundingClientRect(), st = getComputedStyle(e);
            if (st.display === 'none' || st.visibility === 'hidden' || (r.width === 0 && r.height === 0)) continue;
            var ref = e.getAttribute('data-latchkey');
            if (!ref) { ref = 'e' + (next++); e.setAttribute('data-latchkey', ref); }
            var tag = e.tagName.toLowerCase(), type = (e.getAttribute('type') || 'text').toLowerCase();
            var label = (e.getAttribute('aria-label') || e.innerText || e.getAttribute('placeholder') || e.getAttribute('title') || e.getAttribute('name') || e.getAttribute('alt') || '').replace(/\\s+/g, ' ').trim().slice(0, 100);
            var kind = tag === 'a' ? 'link' : tag === 'input' ? ((type === 'submit' || type === 'button') ? 'button' : 'field:' + type) : tag === 'textarea' ? 'field:text' : tag === 'select' ? 'choice' : (e.getAttribute('role') || tag);
            if (!label && tag === 'input' && (type === 'submit' || type === 'button')) label = e.value || '';
            var item = { ref: ref, kind: kind, label: label };
            if (tag === 'a') item.href = e.href;
            if (type === 'checkbox' || type === 'radio') item.checked = e.checked;
            else if (tag === 'input' || tag === 'textarea') {
              var secret = type === 'password' || e.type === 'password' || /(^|\\s)(current-password|new-password|one-time-code|cc-number|cc-csc)(\\s|$)/i.test(e.getAttribute('autocomplete') || '');
              item.value = secret ? (e.value ? '(hidden)' : '') : String(e.value || '').slice(0, 100);
            }
            else if (tag === 'select' && e.selectedIndex >= 0) item.value = e.options[e.selectedIndex].text;
            out.push(item);
          }
          root.setAttribute('data-latchkey-next', String(next));
          var text = (document.body && document.body.innerText) || '';
          return JSON.stringify({ title: document.title, url: location.href, total: text.length, text: text.slice(offset, offset + max), elements: out });
        })(\(max(offset, 0)), \(pageSize))
        """
    }

    private static func find(_ ref: String) -> String {
        "var e = document.querySelector('[data-latchkey=' + JSON.stringify(\(literal(ref))) + ']'); if (!e) return 'missing';"
    }

    static func click(_ ref: String) -> String {
        """
        (function () { \(find(ref))
          if (e.scrollIntoView) e.scrollIntoView({ block: 'center' });
          if (e.focus) e.focus();
          e.click();
          return 'ok';
        })()
        """
    }

    /// Fields take the text as frameworks expect (the native value setter, then input and
    /// change events); choices take an option's text or value; submit uses the field's form.
    static func type(_ ref: String, text: String, submit: Bool) -> String {
        // nosemgrep: latchkey-page-script-literal -- besides literal() and find(), only a Bool.
        """
        (function (text, submit) { \(find(ref))
          if (e.focus) e.focus();
          if (e.tagName === 'SELECT') {
            var o = Array.prototype.find.call(e.options, function (o) { return o.text.trim() === text || o.value === text; });
            if (!o) return 'nooption';
            e.value = o.value;
          } else if (e.isContentEditable) {
            e.textContent = text;
          } else {
            var proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto, 'value').set.call(e, text);
          }
          e.dispatchEvent(new Event('input', { bubbles: true }));
          e.dispatchEvent(new Event('change', { bubbles: true }));
          if (submit) {
            if (e.form) { if (e.form.requestSubmit) e.form.requestSubmit(); else e.form.submit(); }
            else e.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
          }
          return 'ok';
        })(\(literal(text)), \(submit))
        """
    }

    static let back = "(function () { history.back(); return 'ok'; })()"

    static let titleAndAddress = "document.title + '\\t' + location.href"

    /// Put before every script in Claude's tab (spec 005 plan D6): marks the page as Claude's,
    /// so Latchkey finds the tab again after the Owner's tabs moved, and notes where the page is
    /// going when it starts loading another, so Latchkey knows Claude's tab while the new page,
    /// still unmarked, loads. The mark is not enumerable; a page that blocks it only makes
    /// Latchkey lose track of the tab. The note is only the Navigation API's navigate event's
    /// destination, kept in a variable of the listener's own (page code can't write it) and read
    /// through a getter that can't be changed or replaced once set (security review,
    /// 2026-10-29). Installed once per page. `token` is hex.
    static func tabMark(_ token: String) -> String {
        "try { Object.defineProperty(window, '__latchkeyTab', { value: '\(token)', configurable: true }); } catch (e) {}\n"
            + "try { if (window.navigation && !Object.getOwnPropertyDescriptor(window, '__latchkeyGoal')) { (function (nav) { "
            + "var goal = ''; nav.addEventListener('navigate', function (e) { try { goal = String(e.destination.url); } catch (x) {} }); "
            + "Object.defineProperty(window, '__latchkeyGoal', { get: function () { var g = goal; goal = ''; return g; }, configurable: false, enumerable: false }); "
            + "})(window.navigation); } } catch (e) {}\n"
    }

    /// Where the page said it is going since last asked, JSON-encoded (one line), or "" encoded;
    /// asking clears it. Only Latchkey's own getter counts: one that can't be changed and has no
    /// setter; a note the page made first is ignored.
    static let takeDestination = """
        (function () {
          try {
            var d = Object.getOwnPropertyDescriptor(window, '__latchkeyGoal');
            if (!d || typeof d.get !== 'function' || d.set || d.configurable || d.enumerable) return '""';
            return JSON.stringify(String(d.get.call(window)));
          } catch (e) { return '""'; }
        })()
        """

    /// Whether a page carries Claude's mark: "yes" or "no", nothing else of the page.
    static func tabCheck(_ token: String) -> String {
        "window.__latchkeyTab === '\(token)' ? 'yes' : 'no'"
    }

    /// Claude's own script; its result as text.
    static func custom(_ code: String) -> String {
        """
        (function () {
          try {
            var r = (0, eval)(\(literal(code)));
            return typeof r === 'string' ? r : JSON.stringify(r);
          } catch (err) { return 'Error: ' + err; }
        })()
        """
    }
}
