import Foundation

/// The JavaScript that runs inside the Owner's WhatsApp Web tab in Safari (spec 012 plan D1, D2):
/// it defines `window.__latchkey`, whose functions use WhatsApp Web's own modules, never its
/// screen. `WhatsAppBridgeTests` runs it against a stand-in of those modules.
enum WhatsAppBridge {
    /// `window.__latchkey.version`; a tab holding another version gets this one.
    static let version = 3

    static let source = #"""
        // Runs inside the Owner's WhatsApp Web tab (spec 012 plan D2). Defines window.__latchkey, whose
        // functions use WhatsApp Web's own modules (window.require), never its screen. Every function
        // returns plain JSON-able values; Latchkey starts them through Safari and collects the answer.
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
          // Used only by the functions that need them (replies, reactions, deleting, your own chat), so
          // a rename there doesn't stop sending and reading; the function then names what is missing.
          const EXTRA = {
            react: 'WAWebSendReactionMsgAction',
            cmd: 'WAWebCmd',
            capability: 'WAWebMsgActionCapability',
            me: 'WAWebUserPrefsMeUser',
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

          function extra(key) {
            let m = null;
            try { m = window.require(EXTRA[key]); } catch (e) { m = null; }
            if (!m) throw new Error('WhatsApp Web changed in a way this version of Latchkey does not know (missing: ' + EXTRA[key] + '); Latchkey needs an update');
            return m;
          }

          // The Owner's own chat ("Message yourself"), by WhatsApp Web's own idea of who is logged in.
          function meChat(all) {
            const me = extra('me');
            const users = [];
            for (const f of ['getMaybeMePnUser', 'getMaybeMeLidUser', 'getMaybeMeUser']) {
              try { const u = typeof me[f] === 'function' ? me[f]() : null; if (u && u.user) users.push(u.user); } catch (e) { /* not in this version */ }
            }
            return all.find((c) => c.id.server !== 'g.us' && users.includes(c.id.user)) || null;
          }

          // A message of a chat by its key (the id WhatsApp gives it, as whatsapp_read shows it),
          // loading older messages from WhatsApp as needed.
          async function findMsg(chat, key) {
            const k = String(key || '');
            const hit = () => chat.msgs.getModelsArray().find((m) => m.id.id === k || mid(m) === k);
            for (let i = 0; i < 30 && !hit(); i++) {
              const n = chat.msgs.length;
              try { await Promise.race([mod('load').loadEarlierMsgs({ chat }), wait(8000)]); } catch (e) { break; }
              if (chat.msgs.length === n) break;
            }
            return hit() || null;
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
              key: m.id.id || '',
              quoted: m.quotedStanzaID || '',
            };
          }

          window.__latchkey = {
            version: 3,

            // The words on screen while no chats show (a loading or sync screen), for answers
            // that say why WhatsApp isn't connected. Never while chats show: no message text.
            screen() {
              if (document.querySelector('#pane-side')) return { text: '' };
              const t = (document.body ? document.body.innerText : '').replace(/\s+/g, ' ').trim();
              return { text: t.slice(0, 200) };
            },

            // Linked, connected, and whether this WhatsApp Web still has what Latchkey uses.
            state() {
              const gone = missing();
              // Never while chats show: a message's words must not make the page look logged out.
              const chatList = !!document.querySelector('#pane-side');
              const loginScreen = !chatList && (!!document.querySelector('canvas[aria-label], [data-ref]') ||
                /Scan to log in|Log in with phone number|Steps to log in|Enter code on phone|Log in with QR code/.test(document.body ? document.body.innerText.slice(0, 3000) : ''));
              let socket = '';
              let chats = 0;
              try { socket = String(mod('socket').Socket.state || ''); } catch (e) { socket = ''; }
              try { chats = chatsArray().length; } catch (e) { chats = 0; }
              return { loaded: typeof window.require === 'function', chatList, missing: gone, loginScreen, socket, chats, connected: socket === 'CONNECTED' };
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
              if (/^(me|myself|you|message yourself)$/i.test(to)) {
                const own = meChat(all);
                return own ? { match: chatInfo(own) } : { none: true };
              }
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
                  if (m && m.ack >= 1) { known.add(mid(m)); return { id: mid(m), key: m.id.id, ack: m.ack, quoted: m.quotedStanzaID || '' }; }
                  await wait(100);
                }
                return null;
              };
              // A reply quotes the message, as WhatsApp's own Reply does (msgContextInfo).
              let quote = {};
              let quoted = null;
              if (args.replyTo) {
                quoted = await findMsg(chat, args.replyTo);
                if (!quoted) return { error: 'the message to reply to (' + args.replyTo + ') is not in this chat' };
                quote = typeof quoted.msgContextInfo === 'function' ? quoted.msgContextInfo(chat) : { quotedMsg: quoted };
              }
              const quotes = (ok) => !quoted || (ok && ok.quoted === quoted.id.id);
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
                const options = Object.assign(i === 0 ? Object.assign({}, quote) : {}, caption ? { caption } : {});
                await prep.sendToChat({ chat, options });
                const ok = await confirm((m) => (photo ? m.type === 'image' : m.type === 'document'));
                results.push({ file: f.name, sent: !!ok, ack: ok ? ok.ack : 0, key: ok ? ok.key : '', quoted: i === 0 && !!quoted ? quotes(ok) : undefined });
                if (!ok) return { chat: chatInfo(chat), results, incomplete: true };
              }
              if (args.text && files.length === 0) {
                // WhatsApp's own promise can take tens of seconds to settle after the message is out
                // (seen 2026-11-03), so the message itself, in the chat with ack >= 1, is the answer.
                mod('sendText').sendTextMsgToChat(chat, args.text, Object.assign({}, quote)).catch((e) => { failed = String((e && e.message) || e); });
                const ok = await confirm((m) => m.type === 'chat' && m.body === args.text);
                if (failed) return { chat: chatInfo(chat), results, error: failed };
                results.push({ text: true, sent: !!ok, ack: ok ? ok.ack : 0, key: ok ? ok.key : '', quoted: quoted ? quotes(ok) : undefined });
                if (!ok) return { chat: chatInfo(chat), results, incomplete: true };
              }
              return { chat: chatInfo(chat), results };
            },

            // A reaction on a message (emoji), or none ('' takes the Owner's reaction away).
            async react(args) {
              const chat = chatsArray().find((c) => c.id._serialized === args.chat);
              if (!chat) return { error: 'no such chat' };
              const m = await findMsg(chat, args.message);
              if (!m) return { error: 'no such message in this chat' };
              const react = extra('react');
              let failed = null;
              let done = false;
              Promise.resolve(react.sendReactionToMsg(m, args.emoji || '')).then(() => { done = true; }, (e) => { failed = String((e && e.message) || e); });
              const deadline = Date.now() + (args.timeoutMs || 10000);
              while (!done && failed === null && Date.now() < deadline) await wait(100);
              if (failed !== null) return { error: failed };
              return { done, message: msgInfo(m, chat) };
            },

            // Deletes a message: for the Owner only, or for everyone (only the Owner's own, and only
            // while WhatsApp still allows it). Done when WhatsApp has taken it out or marked it deleted.
            async remove(args) {
              const chat = chatsArray().find((c) => c.id._serialized === args.chat);
              if (!chat) return { error: 'no such chat' };
              const m = await findMsg(chat, args.message);
              if (!m) return { error: 'no such message in this chat' };
              const cmd = extra('cmd').Cmd;
              const info = msgInfo(m, chat);
              if (args.everyone) {
                if (!m.id.fromMe) return { refused: 'only your own messages can be deleted for everyone' };
                const cap = extra('capability');
                if (typeof cap.canSenderRevokeMsg === 'function' && !cap.canSenderRevokeMsg(m)) {
                  return { refused: 'WhatsApp no longer allows deleting this message for everyone (it is too old)' };
                }
                cmd.sendRevokeMsgs(chat, { list: [m], type: 'message' }, { clearMedia: true });
              } else {
                cmd.sendDeleteMsgs(chat, { list: [m], type: 'message' }, true);
              }
              const key = m.id.id;
              const deadline = Date.now() + (args.timeoutMs || 10000);
              const gone = () => {
                const now = chat.msgs.getModelsArray().find((x) => x.id.id === key);
                return args.everyone ? !now || now.type === 'revoked' : !now;
              };
              while (!gone() && Date.now() < deadline) await wait(100);
              return { done: gone(), message: info };
            },
          };
        })();
        """#
}
