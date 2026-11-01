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
    if (ago === 0) text = clock.format(t);
    else if (ago === 1) text = "Yesterday, " + clock.format(t);
    else text = (t.getFullYear() === now.getFullYear() ? date : dateYear).format(t) + ", " + clock.format(t);
    el.title = t.toString();
    el.textContent = text;
  }
})();

// Copy buttons: data-copy names the element whose text is copied.
for (const button of document.querySelectorAll("button[data-copy]")) {
  button.addEventListener("click", async () => {
    const source = document.getElementById(button.dataset.copy);
    if (!source) return;
    const label = button.textContent;
    try {
      await navigator.clipboard.writeText(source.textContent.trim());
      button.textContent = "Copied";
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
