const CACHE_NAME = 'cc-remote-v1';
const STATIC_ASSETS = ['/', '/manifest.webmanifest', '/app.js', '/sw.js'];
const sw = self as unknown as {
  addEventListener(type: string, listener: (event: any) => void): void;
  skipWaiting(): Promise<void>;
  clients: { claim(): Promise<void> };
};

sw.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(STATIC_ASSETS)).then(() => sw.skipWaiting()));
});

sw.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key))))
      .then(() => sw.clients.claim()),
  );
});

sw.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (url.origin !== location.origin || shouldNeverCache(url.pathname)) return;

  if (STATIC_ASSETS.includes(url.pathname)) {
    event.respondWith(caches.match(event.request).then(hit => hit || fetch(event.request)));
  }
});

function shouldNeverCache(pathname: string): boolean {
  return pathname.startsWith('/api/') || pathname === '/ws' || pathname.startsWith('/pair');
}
