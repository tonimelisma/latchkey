import Foundation

/// The page scripts of signing in (spec 013 FR-1321, FR-1322, FR-1311; plan D6). They run in the
/// page's main frame only (never in a frame from another site), check the page's own address
/// before filling, and answer "ok", a tab, and JSON, as the browser actions do. Every value is
/// spliced with `literal()`.
extension PageScripts {
    /// The shared helpers: which fields are visible, and which of them is the user name, the
    /// password, or a verification code.
    private static let signInHelpers = """
          function seen(e) {
            if (!e || e.disabled || e.readOnly) return false;
            var s = getComputedStyle(e);
            if (s.visibility === 'hidden' || s.display === 'none' || Number(s.opacity) === 0) return false;
            return !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
          }
          function words(e) {
            var l = '';
            try { if (e.labels && e.labels.length) l = e.labels[0].innerText || ''; } catch (x) {}
            return [e.name, e.id, e.getAttribute('placeholder'), e.getAttribute('aria-label'), e.getAttribute('autocomplete'), l].join(' ');
          }
          var inputs = Array.prototype.filter.call(document.querySelectorAll('input'), seen);
          var typed = function (e) { return ['text', 'email', 'tel', 'number', ''].indexOf((e.getAttribute('type') || '').toLowerCase()) >= 0; };
          var passwords = inputs.filter(function (e) { return e.type === 'password'; });
          var current = passwords.filter(function (e) { return !/new-password/i.test(e.getAttribute('autocomplete') || ''); });
          if (current.length) passwords = current;
          var codeField = inputs.filter(function (e) { return /one-time-code/i.test(e.getAttribute('autocomplete') || ''); })[0]
            || inputs.filter(function (e) {
                 return typed(e) && e.type !== 'password' && (e.maxLength < 0 || e.maxLength >= 4)
                   && /(otp|totp|mfa|2fa|two.?factor|one.?time|verif|security.?code|auth.?code|passcode|pin.?code|\\bcode\\b)/i.test(words(e));
               })[0];
          var boxes = inputs.filter(function (e) { return typed(e) && e.maxLength === 1; });
          if (boxes.length < 6) boxes = [];
          var userField = inputs.filter(function (e) { return /(^|\\s)(username|email)(\\s|$)/i.test(e.getAttribute('autocomplete') || ''); })[0]
            || inputs.filter(function (e) { return e.type === 'email'; })[0]
            || inputs.filter(function (e) { return typed(e) && e !== codeField && /(user|e-?mail|login|account|identifier|phone)/i.test(words(e)); })[0];
          if (passwords.length && userField && passwords[0].form && userField.form !== passwords[0].form) {
            var same = inputs.filter(function (e) { return e.form === passwords[0].form && typed(e) && e !== codeField; })[0];
            if (same) userField = same;
          }
          var captcha = !!document.querySelector('iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[src*="turnstile"], iframe[src*="arkoselabs"], .g-recaptcha, .h-captcha, .cf-turnstile');
          function problem() {
            var all = document.querySelectorAll('[role="alert"], [aria-live="assertive"], .error, .alert, .flash, [class*="error"], [id*="error"]');
            for (var i = 0; i < all.length; i++) {
              var t = (all[i].innerText || '').replace(/\\s+/g, ' ').trim();
              if (t && seen(all[i]) || t && all[i].offsetHeight) return t.slice(0, 300);
            }
            return '';
          }
        """

    /// What the page asks for now: `{ password, code, user, captcha, problem }`. Where the page is
    /// comes from the browser, never from here.
    // nosemgrep: latchkey-page-script-literal -- splices in only the constant signInHelpers.
    static let signInState = """
        (function () {
        \(signInHelpers)
          return 'ok\\t' + JSON.stringify({ password: passwords.length > 0,
            code: !!codeField || boxes.length > 0, user: !!userField, captcha: captcha, problem: problem() });
        })()
        """

    /// Fills what the page asks for and sends it: the password (with the user name when there is
    /// a field for it), else the verification code, else the user name alone (a two-page
    /// sign-in). Latchkey has checked the page's address itself (`SiteMatch`); the script checks
    /// again that the page is still https at `host`, with the browser's own `location` and `===`
    /// only, which no page script can change (security review, 2026-11-21). Answers `{ step }`:
    /// password, code, user, none, or wrongsite.
    static func signInStep(
        host: String, user: String, password: String, code: String, userSent: Bool = false
    ) -> String {
        // nosemgrep: latchkey-page-script-literal -- besides literal(), only the constant signInHelpers.
        """
        (function (host, user, pass, code, userSent) {
          if (location.protocol !== 'https:' || location.hostname !== host) return 'ok\\twrongsite';
        \(signInHelpers)
          var filled = window.__latchkeyFilled;
          if (!filled) {
            filled = [];
            try { Object.defineProperty(window, '__latchkeyFilled', { value: filled, enumerable: false }); } catch (x) {}
          }
          function put(e, v) {
            if (e.focus) e.focus();
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, v);
            e.dispatchEvent(new Event('input', { bubbles: true }));
            e.dispatchEvent(new Event('change', { bubbles: true }));
            filled.push(e);
          }
          function send(e) {
            var form = e.form || (e.closest && e.closest('form'));
            var buttons = form ? Array.prototype.filter.call(form.querySelectorAll('button, input[type="submit"]'), seen) : [];
            var b = buttons.filter(function (b) { return (b.getAttribute('type') || 'submit').toLowerCase() === 'submit'; })[0];
            if (!b) {
              var near = Array.prototype.filter.call(document.querySelectorAll('button, [role="button"], input[type="submit"]'), seen);
              b = near.filter(function (b) { return /^\\s*(sign ?in|log ?in|next|continue|submit|verify|confirm)\\b/i.test(b.innerText || b.value || ''); })[0];
            }
            if (b) { b.click(); return; }
            if (form) { if (form.requestSubmit) form.requestSubmit(); else form.submit(); return; }
            ['keydown', 'keypress', 'keyup'].forEach(function (k) {
              e.dispatchEvent(new KeyboardEvent(k, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
            });
          }
          if (passwords.length && pass) {
            if (userField && user && userField.value !== user) put(userField, user);
            put(passwords[0], pass);
            send(passwords[0]);
            return 'ok\\t' + JSON.stringify({ step: 'password' });
          }
          if ((codeField || boxes.length) && code) {
            if (boxes.length) { boxes.forEach(function (b, i) { put(b, code.charAt(i)); }); send(boxes[boxes.length - 1]); }
            else { put(codeField, code); send(codeField); }
            return 'ok\\t' + JSON.stringify({ step: 'code' });
          }
          if (userField && user && !passwords.length && !userSent) {
            put(userField, user);
            send(userField);
            return 'ok\\t' + JSON.stringify({ step: 'user' });
          }
          return 'ok\\t' + JSON.stringify({ step: 'none' });
        })(\(literal(host)), \(literal(user)), \(literal(password)), \(literal(code)), \(literal(userSent ? "1" : "")) === '1')
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
