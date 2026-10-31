const CACHE_NAME = "lexiaa-cache-v-location-fix-20261031";
const APP_SHELL = ["./", "./index.html", "./app-icon.webp", "./manifest.webmanifest", "./welcome-mascot.webp", "./mascot-member.png", "./welcome-character.png", "./lexiaa-music-character.webp", "./dashboard-characters.png"];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin) return;
  if (url.pathname.includes("/rest/") || url.pathname.includes("/auth/") || url.pathname.includes("/storage/") || url.pathname.includes("/functions/")) return;

  if (request.mode === "navigate") {
    event.respondWith(fetch(request).then(response => {
      if (response.ok) caches.open(CACHE_NAME).then(cache => cache.put("./index.html", response.clone()));
      return response;
    }).catch(() => caches.match("./index.html").then(cached => cached || caches.match("./"))));
    return;
  }

  if (["style", "script", "image", "font"].includes(request.destination)) {
    event.respondWith(caches.match(request).then(cached => {
      const fresh = fetch(request).then(response => {
        if (response.ok) caches.open(CACHE_NAME).then(cache => cache.put(request, response.clone()));
        return response;
      });
      return cached || fresh;
    }));
  }
});
