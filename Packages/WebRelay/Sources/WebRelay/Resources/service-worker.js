const CACHE = "warren-shell-v2";
const SHELL = [
  "/", "/manifest.webmanifest", "/icon.svg", "/icon-192.png", "/icon-512.png",
  "/apple-touch-icon.png",
];
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
  self.skipWaiting();
});
self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key !== CACHE).map(key => caches.delete(key))
  )));
  self.clients.claim();
});
self.addEventListener("fetch", event => {
  if (event.request.method !== "GET" || new URL(event.request.url).pathname === "/ws") return;
  event.respondWith(fetch(event.request).catch(() => caches.match(event.request)));
});
