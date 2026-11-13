// Service worker mínimo: deixa o site instalável e mostra um aviso se estiver sem internet.
// Não guarda dados nem permite agendar offline.
const V = 'bdc-v4-experience';
self.addEventListener('install', (e) => { e.waitUntil(caches.open(V).then((c) => c.addAll(['offline.html', 'css/style.css', 'icons/icon-192.png', 'produtos.html', 'ajuda.html'])).then(() => self.skipWaiting())); });
self.addEventListener('activate', (e) => { e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== V).map((k) => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  const u = new URL(e.request.url);
  if (u.origin !== location.origin) return;           // nunca interfere nas chamadas ao banco
  if (e.request.mode === 'navigate') {
    e.respondWith(fetch(e.request).catch(() => caches.match('offline.html')));
  }
});
