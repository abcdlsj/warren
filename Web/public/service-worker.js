const CACHE = "warren-vite-v12";
const SHELL = [
  "/", "/manifest.webmanifest", "/icon.svg", "/favicon-16.png", "/favicon-32.png", "/icon-192.png", "/icon-512.png",
  "/apple-touch-icon.png", "/assets/app.js", "/assets/app.css",
  "/assets/react.js", "/assets/xterm.js",
];
self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
  self.skipWaiting();
});
self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(
    keys.filter(key => key.startsWith("warren-") && key !== CACHE).map(key => caches.delete(key)),
  )));
  self.clients.claim();
});
self.addEventListener("fetch", event => {
  const pathname = new URL(event.request.url).pathname;
  if (event.request.method !== "GET" || ["/v1/ws", "/v1/client/connect"].includes(pathname)) return;
  event.respondWith(fetch(event.request).catch(() => caches.match(event.request)));
});
