const CACHE_NAME = "lexiaa-global-language-v27";
const APP_SHELL = ["./", "./index.html", "./next-generation.html", "./app-icon.webp", "./manifest.webmanifest", "./welcome-mascot.webp", "./mascot-member.png", "./welcome-character.png", "./lexiaa-music-character.webp", "./dashboard-characters.png", "./about-main-character.png", "./about-intro-character.webm", "./about-feature-character.png", "./about-howto-character.png", "./about-guide-character.png", "./about-tips-character.png", "./about-welcome-character.png", "./lexiaa-story-character-alpha.webm"];

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
    const cacheKey = url.pathname.endsWith("/next-generation.html") ? "./next-generation.html" : "./index.html";
    event.respondWith(fetch(request).then(response => {
      if (response.ok) caches.open(CACHE_NAME).then(cache => cache.put(cacheKey, response.clone()));
      return response;
    }).catch(() => caches.match(cacheKey).then(cached => cached || caches.match("./index.html") || caches.match("./"))));
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
