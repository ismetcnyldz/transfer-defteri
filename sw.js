// Transfer Defteri — bildirim servis çalışanı (önbellek yok, sadece bildirim gösterir)
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of all) { if ("focus" in c) { c.postMessage({ type: "open-booking", id: e.notification.data && e.notification.data.id }); return c.focus(); } }
    return self.clients.openWindow("./");
  })());
});
