// Passkey ceremonies for the Latchkey relay pages. Options arrive as JSON with base64url
// binary fields; the WebAuthn API needs ArrayBuffers, and responses go back as base64url.
"use strict";

const b64 = {
  decode(s) {
    const pad = "=".repeat((4 - (s.length % 4)) % 4);
    const bin = atob((s + pad).replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0)).buffer;
  },
  encode(buf) {
    const bytes = new Uint8Array(buf);
    let bin = "";
    for (const b of bytes) bin += String.fromCharCode(b);
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

function showError(msg) {
  const el = document.getElementById("error");
  if (!el) return alert(msg);
  el.textContent = msg;
  el.hidden = false;
}

function friendly(err) {
  if (err && err.name === "NotAllowedError") return "The passkey request was cancelled or timed out. Try again.";
  if (err && err.name === "InvalidStateError") return "This device already has a passkey for this account. Sign in instead.";
  return (err && err.message) || "Something went wrong. Try again.";
}

async function createPasskey(button) {
  const { purpose, token, next } = button.dataset;
  const begin = await post("/passkey/register/begin", { purpose, token });
  const pk = begin.options.publicKey;
  pk.challenge = b64.decode(pk.challenge);
  pk.user.id = b64.decode(pk.user.id);
  (pk.excludeCredentials || []).forEach((c) => (c.id = b64.decode(c.id)));
  const cred = await navigator.credentials.create({ publicKey: pk });
  const body = {
    id: cred.id,
    rawId: b64.encode(cred.rawId),
    type: cred.type,
    authenticatorAttachment: cred.authenticatorAttachment,
    clientExtensionResults: cred.getClientExtensionResults(),
    response: {
      clientDataJSON: b64.encode(cred.response.clientDataJSON),
      attestationObject: b64.encode(cred.response.attestationObject),
      transports: cred.response.getTransports ? cred.response.getTransports() : [],
    },
  };
  const q = new URLSearchParams({ ceremony: begin.ceremony, next: next || "" });
  const done = await post("/passkey/register/finish?" + q, body);
  location.assign(done.next);
}

async function getPasskey(purpose, next) {
  const begin = await post("/passkey/login/begin", { purpose });
  const pk = begin.options.publicKey;
  pk.challenge = b64.decode(pk.challenge);
  (pk.allowCredentials || []).forEach((c) => (c.id = b64.decode(c.id)));
  const cred = await navigator.credentials.get({ publicKey: pk });
  const body = {
    id: cred.id,
    rawId: b64.encode(cred.rawId),
    type: cred.type,
    authenticatorAttachment: cred.authenticatorAttachment,
    clientExtensionResults: cred.getClientExtensionResults(),
    response: {
      clientDataJSON: b64.encode(cred.response.clientDataJSON),
      authenticatorData: b64.encode(cred.response.authenticatorData),
      signature: b64.encode(cred.response.signature),
      userHandle: cred.response.userHandle ? b64.encode(cred.response.userHandle) : null,
    },
  };
  const q = new URLSearchParams({ ceremony: begin.ceremony, next: next || "" });
  return post("/passkey/login/finish?" + q, body);
}

async function run(button, work) {
  button.disabled = true;
  try {
    await work();
  } catch (err) {
    showError(friendly(err));
  } finally {
    button.disabled = false;
  }
}

document.addEventListener("DOMContentLoaded", () => {
  if (!window.PublicKeyCredential) {
    showError("This browser doesn't support passkeys. Use a current version of Safari, Chrome, Edge, or Firefox.");
  }
  document.querySelectorAll("[data-passkey]").forEach((button) => {
    button.addEventListener("click", () =>
      run(button, async () => {
        if (button.dataset.passkey === "create") return createPasskey(button);
        const done = await getPasskey("signin", button.dataset.next);
        location.assign(done.next);
      }),
    );
  });
  document.querySelectorAll("form[data-reauth]").forEach((form) => {
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (!confirm("Delete your Latchkey account? This can't be undone.")) return;
      const button = form.querySelector("button[type=submit]");
      run(button, async () => {
        await getPasskey("reauth", "");
        form.submit();
      });
    });
  });
});
