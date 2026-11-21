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
          // A challenge counts only when the page shows it: ad scripts add hidden reCAPTCHA
          // frames, and invisible reCAPTCHA shows only its badge (homerecording.com, 2026-11-21).
          var captcha = Array.prototype.some.call(document.querySelectorAll('iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[src*="turnstile"], iframe[src*="arkoselabs"], .g-recaptcha, .h-captcha, .cf-turnstile'), function (e) {
            if (e.closest('.grecaptcha-badge')) return false;
            if (e.tagName === 'IFRAME' && /size=invisible|\\/aframe/i.test(e.getAttribute('src') || '')) return false;
            var s = getComputedStyle(e);
            if (s.visibility === 'hidden' || s.display === 'none' || Number(s.opacity) === 0) return false;
            return e.offsetWidth > 0 && e.offsetHeight > 0;
          });
          // The site's own words about the sign-in: a shown error element first, then a shown
          // alert; never a link (Citi's "Skip to Content" link is marked as a live region).
          function problem() {
            var groups = ['.error, [class*="error"], [id*="error"]', '[role="alert"], [aria-live="assertive"], .alert, .flash'];
            for (var g = 0; g < groups.length; g++) {
              var all = document.querySelectorAll(groups[g]);
              for (var i = 0; i < all.length; i++) {
                var el = all[i];
                if (el.tagName === 'A' || (el.closest && el.closest('a'))) continue;
                var t = (el.innerText || '').replace(/\\s+/g, ' ').trim();
                if (!t || /^skip to\\b/i.test(t) || !(el.offsetWidth || el.offsetHeight)) continue;
                // A notice about something else (Citi's holiday scam warning, 2026-11-21) is long:
                // the site's words about a sign-in are a sentence or two.
                if (t.length > 160 || /^alert section/i.test(t)) continue;
                var s = getComputedStyle(el);
                if (s.visibility === 'hidden' || s.display === 'none') continue;
                return t.slice(0, 300);
              }
            }
            return '';
          }
          // A step asking how to send the code ("We'll send a code to +1 ••• 0790": Text me / Call
          // me; Citi, 2026-11-21): the buttons that send it, by text message first, then email.
          var delivery = Array.prototype.filter.call(document.querySelectorAll('button, [role="button"], input[type="submit"], input[type="button"], a'), seen)
            .map(function (b) { return { el: b, t: (b.innerText || b.value || '').replace(/\\s+/g, ' ').trim() }; })
            .filter(function (x) { return x.t.length < 40; });
          var bySms = delivery.filter(function (x) { return /^(text( me)?|send (me )?(a )?(text|sms)( message)?|sms|text message)\\b/i.test(x.t); })[0];
          var byMail = delivery.filter(function (x) { return /^(email( me)?|send (me )?(an )?email|e-mail( me)?)\\b/i.test(x.t); })[0];
          var deliver = bySms || byMail;
        """

    /// What the page asks for now: `{ password, code, user, captcha, problem }`. Where the page is
    /// comes from the browser, never from here.
    // nosemgrep: latchkey-page-script-literal -- splices in only the constant signInHelpers.
    static let signInState = """
        (function () {
        \(signInHelpers)
          return 'ok\\t' + JSON.stringify({ password: passwords.length > 0,
            code: !!codeField || boxes.length > 0, user: !!userField, captcha: captcha, problem: problem(),
            deliver: !!deliver && !codeField && !boxes.length });
        })()
        """

    /// Fills what the page asks for and sends it: the password (with the user name when there is
    /// a field for it), else the verification code, else the user name alone (a two-page
    /// sign-in). Latchkey has checked the page's address itself (`SiteMatch`); the script checks
    /// again that the page is still https at `host`, with the browser's own `location` and `===`
    /// only, which no page script can change (security review, 2026-11-21). Answers `{ step }`:
    /// password, code, user, none, or wrongsite.
    static func signInStep(
        host: String, user: String, password: String, code: String, userSent: Bool = false,
        passwordSent: Bool = false
    ) -> String {
        // nosemgrep: latchkey-page-script-literal -- besides literal(), only the constant signInHelpers.
        """
        (function (host, user, pass, code, userSent, passwordSent) {
          if (location.protocol !== 'https:' || location.hostname !== host) return 'ok\\twrongsite';
        \(signInHelpers)
          var filled = window.__latchkeyFilled;
          if (!filled) {
            filled = [];
            try { Object.defineProperty(window, '__latchkeyFilled', { value: filled, enumerable: false }); } catch (x) {}
          }
          // Typed one character at a time, as a keyboard does (key events with codes, beforeinput,
          // the text put in at the caret, input): input masks take nothing else (Citi's user ID
          // kept only "uu" of "dummyuser", 2026-11-21). A page script may handle a key itself
          // (preventDefault); then its own handling stands. True when the field holds the value.
          var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          function put(e, v) {
            if (e.focus) e.focus();
            filled.push(e);
            setter.call(e, '');
            e.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
            for (var i = 0; i < v.length; i++) {
              var ch = v.charAt(i), up = ch.toUpperCase();
              var code = /[a-z]/i.test(ch) ? 'Key' + up : (/[0-9]/.test(ch) ? 'Digit' + ch : '');
              var kc = /[a-z0-9]/i.test(ch) ? up.charCodeAt(0) : 0;
              var go = e.dispatchEvent(new KeyboardEvent('keydown', { key: ch, code: code, keyCode: kc, which: kc, bubbles: true, cancelable: true }));
              go = e.dispatchEvent(new KeyboardEvent('keypress', { key: ch, code: code, keyCode: ch.charCodeAt(0), charCode: ch.charCodeAt(0), which: ch.charCodeAt(0), bubbles: true, cancelable: true })) && go;
              go = e.dispatchEvent(new InputEvent('beforeinput', { data: ch, inputType: 'insertText', bubbles: true, cancelable: true })) && go;
              if (go) {
                var was = e.value, s = e.selectionStart, t = e.selectionEnd;
                if (s === null || s === undefined) { s = was.length; t = was.length; }
                setter.call(e, was.slice(0, s) + ch + was.slice(t));
                try { e.setSelectionRange(s + 1, s + 1); } catch (x) {}
                e.dispatchEvent(new InputEvent('input', { data: ch, inputType: 'insertText', bubbles: true }));
              }
              e.dispatchEvent(new KeyboardEvent('keyup', { key: ch, code: code, keyCode: kc, which: kc, bubbles: true }));
            }
            e.dispatchEvent(new Event('change', { bubbles: true }));
            if (e.blur) e.blur();
            var squash = function (s) { return String(s).replace(/[\\s-]/g, ''); };
            return squash(e.value) === squash(v);
          }
          function send(e) {
            var form = e.form || (e.closest && e.closest('form'));
            var buttons = form ? Array.prototype.filter.call(form.querySelectorAll('button, input[type="submit"]'), seen) : [];
            var b = buttons.filter(function (b) { return (b.getAttribute('type') || 'submit').toLowerCase() === 'submit'; })[0];
            if (!b) {
              var near = Array.prototype.filter.call(document.querySelectorAll('button, [role="button"], input[type="submit"]'), seen);
              b = near.filter(function (b) { return /^\\s*(sign ?in|sign ?on|log ?in|log ?on|next|continue|submit|verify|confirm)\\b/i.test(b.innerText || b.value || ''); })[0];
            }
            if (b) { b.click(); return; }
            if (form) { if (form.requestSubmit) form.requestSubmit(); else form.submit(); return; }
            ['keydown', 'keypress', 'keyup'].forEach(function (k) {
              e.dispatchEvent(new KeyboardEvent(k, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
            });
          }
          // Nothing is sent when a field doesn't hold what was typed: the site would refuse an
          // empty or changed form, and that is no refusal of the password (Citi, 2026-11-21).
          var unfilled = 'ok\\t' + JSON.stringify({ step: 'unfilled' });
          // After the password, a step asking how to send the code: its text-message button (or
          // email), never before (a sign-in page may offer "email me a link" beside the password).
          if (passwordSent && deliver && !codeField && !boxes.length) {
            deliver.el.click();
            return 'ok\\t' + JSON.stringify({ step: 'delivery' });
          }
          if (passwords.length && pass) {
            if (userField && user && userField.value !== user && !put(userField, user)) return unfilled;
            if (!put(passwords[0], pass)) return unfilled;
            send(passwords[0]);
            return 'ok\\t' + JSON.stringify({ step: 'password' });
          }
          if ((codeField || boxes.length) && code) {
            if (boxes.length) {
              var all = true;
              boxes.forEach(function (b, i) { all = put(b, code.charAt(i)) && all; });
              if (!all) return unfilled;
              send(boxes[boxes.length - 1]);
            } else {
              if (!put(codeField, code)) return unfilled;
              send(codeField);
            }
            return 'ok\\t' + JSON.stringify({ step: 'code' });
          }
          if (userField && user && !passwords.length && !userSent) {
            if (!put(userField, user)) return unfilled;
            send(userField);
            return 'ok\\t' + JSON.stringify({ step: 'user' });
          }
          return 'ok\\t' + JSON.stringify({ step: 'none' });
        })(\(literal(host)), \(literal(user)), \(literal(password)), \(literal(code)), \(literal(userSent ? "1" : "")) === '1', \(literal(passwordSent ? "1" : "")) === '1')
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
