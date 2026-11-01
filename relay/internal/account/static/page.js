// Small helpers for the relay's pages; each page works without them.
"use strict";

// Times in the viewer's own time zone (FR-657). The server writes UTC; here it becomes
// "3:29 PM" today, "Yesterday, 3:29 PM", or "Oct 30, 3:29 PM" (with the year when not this year).
(function localTimes() {
  const now = new Date();
  const day = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const today = day(now);
  const clock = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
  const date = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" });
  const dateYear = new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" });
  for (const el of document.querySelectorAll("time[datetime]")) {
    const t = new Date(el.getAttribute("datetime"));
    if (isNaN(t)) continue;
    const ago = (today - day(t)) / 86400000;
    let text;
    if (ago === 0 || el.closest("ol.activity")) text = clock.format(t); // the list has day headings
    else if (ago === 1) text = "Yesterday, " + clock.format(t);
    else text = (t.getFullYear() === now.getFullYear() ? date : dateYear).format(t) + ", " + clock.format(t);
    el.title = t.toString();
    el.textContent = text;
  }

  // The activity list gets a heading for each day, so a long list can be scanned by day.
  const dayName = new Intl.DateTimeFormat(undefined, { weekday: "long", month: "short", day: "numeric" });
  const dayNameYear = new Intl.DateTimeFormat(undefined, { weekday: "long", month: "short", day: "numeric", year: "numeric" });
  for (const list of document.querySelectorAll("ol.activity")) {
    let last = null;
    for (const item of [...list.querySelectorAll(":scope > li.entry")]) {
      const el = item.querySelector("time[datetime]");
      const t = el && new Date(el.getAttribute("datetime"));
      if (!t || isNaN(t)) continue;
      const d = day(t);
      if (d === last) continue;
      last = d;
      const ago = (today - d) / 86400000;
      const head = document.createElement("li");
      head.className = "day";
      head.textContent = ago === 0 ? "Today" : ago === 1 ? "Yesterday"
        : (t.getFullYear() === now.getFullYear() ? dayName : dayNameYear).format(t);
      list.insertBefore(head, item);
    }
  }
})();

// Removals ask first (data-confirm holds the question); without the script they go ahead.
for (const form of document.querySelectorAll("form[data-confirm]")) {
  form.addEventListener("submit", (event) => {
    if (!window.confirm(form.dataset.confirm)) event.preventDefault();
  });
}

// A message saying what just happened takes the focus, so screen readers read it on arrival.
document.querySelector("[data-focus]")?.focus();

// Copy buttons: data-copy names the element whose text is copied. A hidden live region tells
// screen readers it worked.
const copyStatus = document.createElement("span");
copyStatus.className = "visually-hidden";
copyStatus.setAttribute("aria-live", "polite");
document.body.append(copyStatus);
for (const button of document.querySelectorAll("button[data-copy]")) {
  button.addEventListener("click", async () => {
    const source = document.getElementById(button.dataset.copy);
    if (!source) return;
    const label = button.textContent;
    try {
      await navigator.clipboard.writeText(source.textContent.trim());
      button.textContent = "Copied";
      copyStatus.textContent = "Copied to the clipboard.";
    } catch {
      // No clipboard access: select the text so the viewer can copy it themselves.
      const range = document.createRange();
      range.selectNodeContents(source);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      button.textContent = "Selected";
    }
    setTimeout(() => { button.textContent = label; }, 2000);
  });
}
