import Foundation

/// The JavaScript that runs inside Latchkey's WhatsApp Web page (spec 012 plan D2): it defines
/// `window.__latchkey`, whose functions use WhatsApp Web's own modules, never its screen.
/// `WhatsAppBridgeTests` runs it against a stand-in of those modules.
enum WhatsAppBridge {
    static let source = #"""
        // Runs inside Latchkey's hidden WhatsApp Web page (spec 012 plan D2). Defines window.__latchkey,
        // whose functions use WhatsApp Web's own modules (window.require), never its screen. Every
        // function returns plain JSON-able values; Swift calls them with callAsyncJavaScript.
        (function () {
          'use strict';
          const MODULES = {
            collections: 'WAWebCollections',
            socket: 'WAWebSocketModel',
            findChat: 'WAWebFindChatAction',
            wid: 'WAWebWidFactory',
            sendText: 'WAWebSendTextMsgChatAction',
            opaque: 'WAWebMediaOpaqueData',
            prep: 'WAWebPrepRawMedia',
            load: 'WAWebChatLoadMessages',
          };
          const wait = (ms) => new Promise((r) => setTimeout(r, ms));
          const clean = (s) => String(s || '').replace(/[‎‏‪-‮⁦-⁩]/g, '').trim();
          const fold = (s) => clean(s).toLocaleLowerCase();
          // A message's id has no _serialized (a chat's does); its text form is the full key.
          const mid = (m) => String(m.id);
          const digits = (s) => String(s || '').replace(/\D/g, '');

          function mod(key) {
            if (typeof window.require !== 'function') throw new Error('WhatsApp Web has not loaded');
            return window.require(MODULES[key]);
          }

          // Which of WhatsApp Web's modules are missing (an update renamed them).
          function missing() {
            if (typeof window.require !== 'function') return Object.values(MODULES);
            return Object.values(MODULES).filter((name) => {
              try { return !window.require(name); } catch (e) { return true; }
            });
          }

          function chatsArray() { return mod('collections').Chat.getModelsArray(); }

          function chatInfo(c) {
            const last = c.msgs && c.msgs.length ? c.msgs.getModelsArray()[c.msgs.length - 1] : null;
            return {
              id: c.id._serialized,
              name: clean(c.formattedTitle || c.name || (c.contact && c.contact.name) || c.id.user),
              group: c.id.server === 'g.us',
              unread: Math.max(0, c.unreadCount || 0),
              time: c.t || (last ? last.t : 0) || 0,
              number: c.id.server === 'c.us' ? c.id.user : (c.contact && c.contact.phoneNumber ? c.contact.phoneNumber.user : ''),
            };
          }

          function msgType(m) {
            const t = m.type;
            if (t === 'chat') return 'text';
            if (t === 'ptt' || t === 'audio') return 'voice';
            if (t === 'image' || t === 'video' || t === 'document' || t === 'sticker' || t === 'location') return t;
            if (t === 'vcard' || t === 'multi_vcard') return 'contact';
            if (t === 'revoked') return 'deleted';
            return t || 'other';
          }

          function msgInfo(m, chat) {
            let sender = 'You';
            if (!m.id.fromMe) {
              const c = m.senderObj || (m.author && mod('collections').Contact.get(m.author)) || chat.contact;
              sender = clean((c && (c.name || c.pushname || c.verifiedName)) || (m.author && m.author.user) || chat.formattedTitle);
            }
            return {
              id: mid(m),
              time: m.t || 0,
              fromMe: !!m.id.fromMe,
              sender,
              type: msgType(m),
              text: clean(m.type === 'chat' ? m.body : (m.caption || '')),
              fileName: m.filename || '',
              ack: m.ack || 0,
            };
          }

          window.__latchkey = {
            version: 1,

            // Linked, connected, and whether this WhatsApp Web still has what Latchkey uses.
            state() {
              const gone = missing();
              const loginScreen = !!document.querySelector('canvas[aria-label], [data-ref]') ||
                /Scan to log in|Log in with phone number|Steps to log in/.test(document.body ? document.body.innerText.slice(0, 3000) : '');
              let socket = '';
              let chats = 0;
              try { socket = String(mod('socket').Socket.state || ''); } catch (e) { socket = ''; }
              try { chats = chatsArray().length; } catch (e) { chats = 0; }
              return { loaded: typeof window.require === 'function', chatList: !!document.querySelector('#pane-side'), missing: gone, loginScreen, socket, chats, connected: socket === 'CONNECTED' };
            },

            // Chats newest first; query matches a name or a number.
            chats(args) {
              const q = fold(args.query);
              const qd = digits(args.query);
              let list = chatsArray().map(chatInfo).filter((c) => !c.id.endsWith('@broadcast') && c.id !== 'status@broadcast');
              if (q) list = list.filter((c) => fold(c.name).includes(q) || (qd.length >= 4 && c.number.includes(qd)));
              if (args.unread) list = list.filter((c) => c.unread > 0);
              list.sort((a, b) => b.time - a.time);
              const offset = args.offset || 0;
              return { total: list.length, chats: list.slice(offset, offset + (args.limit || 25)) };
            },

            // One chat for `to`: its id, a name (exact, else the only one containing it), or a phone number.
            async resolve(args) {
              const to = clean(args.to);
              if (!to) return { none: true };
              const all = chatsArray();
              // The desktop app's ids name people @s.whatsapp.net where WhatsApp Web says @c.us.
              const asWeb = to.replace(/@s\.whatsapp\.net$/, '@c.us');
              const byId = all.find((c) => c.id._serialized === asWeb);
              if (byId) return { match: chatInfo(byId) };
              const d = digits(to.split('@')[0]);
              if (d.length >= 7 && /^([+\d\s().-]+|\d+@(c\.us|s\.whatsapp\.net))$/.test(to)) {
                const known = all.find((c) => chatInfo(c).number === d);
                if (known) return { match: chatInfo(known) };
                const wid = mod('wid').createWid(d + '@c.us');
                const r = await mod('findChat').findOrCreateLatestChat(wid);
                const chat = (r && r.chat) || r;
                if (!chat || !chat.id) return { none: true };
                return { match: chatInfo(chat) };
              }
              const f = fold(to);
              const exact = all.filter((c) => fold(chatInfo(c).name) === f);
              if (exact.length === 1) return { match: chatInfo(exact[0]) };
              const pool = exact.length > 1 ? exact : all.filter((c) => fold(chatInfo(c).name).includes(f));
              if (pool.length === 1) return { match: chatInfo(pool[0]) };
              if (pool.length === 0) return { none: true };
              return { candidates: pool.map(chatInfo).sort((a, b) => b.time - a.time).slice(0, 10) };
            },

            // A chat's messages, newest first, loading older ones from WhatsApp as needed.
            async messages(args) {
              const chat = chatsArray().find((c) => c.id._serialized === args.chat);
              if (!chat) return { none: true };
              const want = (args.limit || 25) + (args.offset || 0);
              const before = args.before || Infinity;
              const older = () => chat.msgs.getModelsArray().filter((m) => (m.t || 0) < before);
              for (let i = 0; i < 40 && older().length < want; i++) {
                const n = chat.msgs.length;
                try { await Promise.race([mod('load').loadEarlierMsgs({ chat }), wait(8000)]); } catch (e) { break; }
                if (chat.msgs.length === n) break;
              }
              const list = older().filter((m) => !m.isNotification).map((m) => msgInfo(m, chat)).reverse();
              const all = chat.msgs.getModelsArray();
              return {
                chat: chatInfo(chat),
                oldest: all.length ? all[0].t : 0,
                messages: list.slice(args.offset || 0, want),
              };
            },

            // Messages whose text contains `query`, in the chats WhatsApp Web has in memory.
            search(args) {
              const q = fold(args.query);
              const since = args.since || 0;
              const until = args.until || Infinity;
              const hits = [];
              let oldest = Infinity;
              for (const chat of chatsArray()) {
                if (args.chat && chat.id._serialized !== args.chat) continue;
                for (const m of chat.msgs.getModelsArray()) {
                  oldest = Math.min(oldest, m.t || Infinity);
                  const t = m.t || 0;
                  if (t < since || t >= until) continue;
                  const text = fold(m.type === 'chat' ? m.body : m.caption);
                  if (q && !text.includes(q)) continue;
                  hits.push(Object.assign(msgInfo(m, chat), { chat: chatInfo(chat).name, chatId: chat.id._serialized }));
                }
              }
              hits.sort((a, b) => b.time - a.time);
              const offset = args.offset || 0;
              return { total: hits.length, oldest: oldest === Infinity ? 0 : oldest, messages: hits.slice(offset, offset + (args.limit || 25)) };
            },

            // Sends text and files to a chat and waits until WhatsApp has each (ack >= 1).
            // files: [{name, type, base64}]. The text goes as the first file's caption when there are files.
            async send(args) {
              const chat = chatsArray().find((c) => c.id._serialized === args.chat);
              if (!chat) return { error: 'no such chat' };
              const deadline = Date.now() + (args.timeoutMs || 20000);
              const mine = () => chat.msgs.getModelsArray().filter((m) => m.id.fromMe);
              const known = new Set(mine().map(mid));
              const results = [];
              let failed = null;
              const confirm = async (pred) => {
                while (Date.now() < deadline && failed === null) {
                  const m = mine().find((x) => !known.has(mid(x)) && pred(x));
                  if (m && m.ack >= 1) { known.add(mid(m)); return { id: mid(m), ack: m.ack }; }
                  await wait(100);
                }
                return null;
              };
              const files = args.files || [];
              for (let i = 0; i < files.length; i++) {
                const f = files[i];
                const bytes = Uint8Array.from(atob(f.base64), (ch) => ch.charCodeAt(0));
                const file = new File([bytes], f.name, { type: f.type || 'application/octet-stream' });
                const photo = /^image\/(png|jpe?g|gif|webp|heic)$/i.test(file.type);
                const data = await mod('opaque').createFromData(file, file.type);
                const prep = mod('prep').prepRawMedia(data, { asStickerUpload: false, asGif: false, isPtt: false, asDocument: !photo });
                await prep.waitForPrep();
                const caption = i === 0 && args.text ? args.text : undefined;
                await prep.sendToChat({ chat, options: caption ? { caption } : {} });
                const ok = await confirm((m) => (photo ? m.type === 'image' : m.type === 'document'));
                results.push({ file: f.name, sent: !!ok, ack: ok ? ok.ack : 0 });
                if (!ok) return { chat: chatInfo(chat), results, incomplete: true };
              }
              if (args.text && files.length === 0) {
                // WhatsApp's own promise can take tens of seconds to settle after the message is out
                // (seen 2026-11-03), so the message itself, in the chat with ack >= 1, is the answer.
                mod('sendText').sendTextMsgToChat(chat, args.text).catch((e) => { failed = String((e && e.message) || e); });
                const ok = await confirm((m) => m.type === 'chat' && m.body === args.text);
                if (failed) return { chat: chatInfo(chat), results, error: failed };
                results.push({ text: true, sent: !!ok, ack: ok ? ok.ack : 0 });
                if (!ok) return { chat: chatInfo(chat), results, incomplete: true };
              }
              return { chat: chatInfo(chat), results };
            },

            // On the log-in screen: asks WhatsApp for an 8-character code to type on the phone (Linked
            // Devices → Link a Device → Link with phone number instead). The only use of the screen: the
            // log-in screen has no module to call (2026-11-02: these steps linked Toni's phone).
            async linkByPhone(args) {
              const number = digits(args.number);
              if (number.length < 7) return { error: 'a phone number with its country code is needed' };
              const text = () => (document.body ? document.body.innerText : '');
              const readCode = () => {
                const t = text();
                const spread = t.match(/\n([A-Z0-9])\n([A-Z0-9])\n([A-Z0-9])\n([A-Z0-9])\n-\n([A-Z0-9])\n([A-Z0-9])\n([A-Z0-9])\n([A-Z0-9])(?:\n|$)/);
                if (spread) return spread.slice(1, 5).join('') + '-' + spread.slice(5, 9).join('');
                const joined = t.match(/\b([A-Z0-9]{4})-([A-Z0-9]{4})\b/);
                return joined ? joined[1] + '-' + joined[2] : '';
              };
              const until = async (f, ms) => { for (let i = 0; i < ms / 200; i++) { const v = f(); if (v) return v; await wait(200); } return null; };
              const leaf = (re) => [...document.querySelectorAll('*')].find((e) => e.children.length === 0 && re.test((e.textContent || '').trim()));
              const press = (e) => (e.closest('button,[role=button],a,[tabindex]') || e).click();
              const start = await until(() => leaf(/^Log in with phone number$/) || document.querySelector('input[aria-label*="phone number"]'), 20000);
              if (!start) return { error: 'the log-in screen did not show' };
              // A press before WhatsApp Web has set up its handlers does nothing (2026-11-03, in
              // Latchkey's page), so it is pressed again until the field shows.
              const field = () => document.querySelector('input[aria-label*="phone number"]');
              let input = field();
              for (let i = 0; i < 16 && !input; i++) {
                const link = leaf(/^Log in with phone number$/);
                if (link) press(link);
                input = await until(field, 1500);
              }
              if (!input) return { error: 'the phone number field did not show' };
              input.focus();
              document.execCommand('selectAll');
              document.execCommand('insertText', false, '+' + number);
              await wait(600);
              const next = [...document.querySelectorAll('button,[role=button]')].find((b) => /^Next$/.test((b.innerText || '').trim()));
              if (!next) return { error: 'the Next button did not show' };
              next.click();
              const code = await until(readCode, 20000);
              return code ? { code } : { error: 'WhatsApp did not show a code' };
            },

            // WhatsApp Web's own log-out, which also removes this device from the phone's Linked Devices.
            async logout() {
              try {
                // The connection's own log-out (whatsapp-web.js's too); WAWebCmd has none (2026-11-03).
                await mod('socket').Socket.logout();
                return { ok: true };
              } catch (e) {
                return { ok: false, error: String(e && e.message) };
              }
            },
          };
        })();
        """#
}
