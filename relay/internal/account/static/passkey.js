// Sign-in for the Latchkey relay: email first, then a passkey (known account) or an emailed code
// and a new passkey (new account, or recovery). Passkeys are also offered in the email field's
// autofill. Options arrive as JSON with base64url binary fields; WebAuthn needs ArrayBuffers.
"use strict";

const b64 = {
  decode(s) {
    const pad = "=".repeat((4 - (s.length % 4)) % 4);
    const bin = atob((s + pad).replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0)).buffer;
  },
  encode(buf) {
    let bin = "";
    for (const b of new Uint8Array(buf)) bin += String.fromCharCode(b);
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
};

async function post(url, body) {
  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    credentials: "same-origin",
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(data.error || "Something went wrong. Try again.");
  return data;
}

function friendly(err) {
  if (err && err.name === "NotAllowedError") return "The passkey request was cancelled or timed out. Try again.";
  if (err && err.name === "InvalidStateError") return "This device already has a passkey for this account. Go back and sign in.";
  if (err && err.name === "AbortError") return "";
  return (err && err.message) || "Something went wrong. Try again.";
}

function assertionBody(cred) {
  return {
    id: cred.id, rawId: b64.encode(cred.rawId), type: cred.type,
    authenticatorAttachment: cred.authenticatorAttachment,
    clientExtensionResults: cred.getClientExtensionResults(),
    response: {
      clientDataJSON: b64.encode(cred.response.clientDataJSON),
      authenticatorData: b64.encode(cred.response.authenticatorData),
      signature: b64.encode(cred.response.signature),
      userHandle: cred.response.userHandle ? b64.encode(cred.response.userHandle) : null,
    },
  };
}

/** Signs in with a passkey; mediation "conditional" waits in the email field's autofill. */
async function getPasskey(purpose, next, mediation, signal) {
  const begin = await post("/passkey/login/begin", { purpose });
  const pk = begin.options.publicKey;
  pk.challenge = b64.decode(pk.challenge);
  (pk.allowCredentials || []).forEach((c) => (c.id = b64.decode(c.id)));
  const cred = await navigator.credentials.get({ publicKey: pk, mediation, signal });
  const q = new URLSearchParams({ ceremony: begin.ceremony, next: next || "" });
  return post("/passkey/login/finish?" + q, assertionBody(cred));
}

async function createPasskey(ticket, next) {
  const begin = await post("/passkey/register/begin", { ticket });
  const pk = begin.options.publicKey;
  pk.challenge = b64.decode(pk.challenge);
  pk.user.id = b64.decode(pk.user.id);
  (pk.excludeCredentials || []).forEach((c) => (c.id = b64.decode(c.id)));
  const cred = await navigator.credentials.create({ publicKey: pk });
  const body = {
    id: cred.id, rawId: b64.encode(cred.rawId), type: cred.type,
    authenticatorAttachment: cred.authenticatorAttachment,
    clientExtensionResults: cred.getClientExtensionResults(),
    response: {
      clientDataJSON: b64.encode(cred.response.clientDataJSON),
      attestationObject: b64.encode(cred.response.attestationObject),
      transports: cred.response.getTransports ? cred.response.getTransports() : [],
    },
  };
  const q = new URLSearchParams({ ceremony: begin.ceremony, next: next || "" });
  return post("/passkey/register/finish?" + q, body);
}

function setupFlow(flow) {
  const next = flow.dataset.next || "/account";
  const recover = flow.dataset.recover === "1";
  const state = { email: "", purpose: "", ticket: "" };
  let autofill = null; // AbortController of the waiting autofill request

  flow.querySelectorAll("[data-title-normal],[data-text-normal]").forEach((el) => (el.hidden = recover));
  flow.querySelectorAll("[data-title-recover],[data-text-recover]").forEach((el) => (el.hidden = !recover));

  const show = (step) => {
    flow.querySelectorAll("[data-step]").forEach((s) => (s.hidden = s.dataset.step !== step));
    flow.querySelectorAll("[data-email]").forEach((el) => (el.textContent = state.email));
    flow.querySelectorAll("[data-error]").forEach((el) => (el.hidden = true));
    const focus = flow.querySelector(`[data-step="${step}"] input, [data-step="${step}"] button.primary`);
    if (focus) focus.focus();
  };
  const error = (step, msg) => {
    const el = flow.querySelector(step === "email" ? "#error" : `[data-step="${step}"] [data-error]`);
    if (!msg) return;
    el.textContent = msg;
    el.hidden = false;
  };
  const busy = async (button, work) => {
    button.disabled = true;
    try { await work(); } finally { button.disabled = false; }
  };
  // Only ever go to a page on this site, whatever the server or the link said.
  const sameOrigin = (target) => {
    try {
      return new URL(target, location.origin).origin === location.origin;
    } catch {
      return false;
    }
  };
  const done = (result) => {
    const target = result.next || next;
    location.assign(sameOrigin(target) ? target : "/account");
  };

  // Passkey autofill on the email field: one tap for a returning user.
  const startAutofill = async () => {
    if (recover || !window.PublicKeyCredential || !PublicKeyCredential.isConditionalMediationAvailable) return;
    if (!(await PublicKeyCredential.isConditionalMediationAvailable())) return;
    autofill = new AbortController();
    try {
      done(await getPasskey("signin", next, "conditional", autofill.signal));
    } catch {
      // Autofill runs in the background; the Owner didn't ask for it, so a refusal stays quiet.
    }
  };
  const stopAutofill = () => { if (autofill) autofill.abort(); autofill = null; };

  flow.querySelector("#email-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const button = event.submitter || event.target.querySelector("button");
    busy(button, async () => {
      state.email = flow.querySelector("#email").value.trim();
      try {
        const r = await post("/auth/email", { email: state.email, recover });
        stopAutofill();
        state.purpose = r.purpose || "";
        show(r.step);
      } catch (err) {
        error("email", friendly(err));
      }
    });
  });

  flow.querySelector("#code-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const button = event.submitter || event.target.querySelector("button");
    busy(button, async () => {
      try {
        const r = await post("/auth/code", { email: state.email, code: flow.querySelector("#code").value, purpose: state.purpose });
        state.ticket = r.ticket;
        show("create");
      } catch (err) {
        error("code", friendly(err));
      }
    });
  });
  const code = flow.querySelector("#code");
  code.addEventListener("input", () => {
    if (code.value.replace(/\D/g, "").length === 6) flow.querySelector("#code-form").requestSubmit();
  });

  flow.querySelectorAll("[data-action]").forEach((button) => {
    button.addEventListener("click", () => {
      const action = button.dataset.action;
      if (action === "back") { show("email"); startAutofill(); return; }
      busy(button, async () => {
        try {
          if (action === "signin") done(await getPasskey("signin", next, "optional"));
          if (action === "create") done(await createPasskey(state.ticket, next));
        } catch (err) {
          error(action === "signin" ? "passkey" : "create", friendly(err));
        }
      });
    });
  });

  if (!window.PublicKeyCredential) {
    error("email", "This browser doesn't support passkeys. Use a current version of Safari, Chrome, Edge, or Firefox.");
  }
  startAutofill();
}

document.addEventListener("DOMContentLoaded", () => {
  const flow = document.getElementById("flow");
  if (flow) setupFlow(flow);

  document.querySelectorAll("form[data-reauth]").forEach((form) => {
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (!confirm("Delete your Latchkey account? This can't be undone.")) return;
      const button = form.querySelector("button[type=submit]");
      button.disabled = true;
      getPasskey("reauth", "", "optional")
        .then(() => form.submit())
        .catch((err) => {
          const el = form.querySelector("#error");
          el.textContent = friendly(err);
          el.hidden = false;
        })
        .finally(() => (button.disabled = false));
    });
  });
});
