self.addEventListener('install', (event) => {
  console.log(event);
  // self.skipWaiting();
  // event.waitUntil(
  //   caches.open('jmeu')
  //     .then(cache => cache.addAll([
  //       '/jmeu/index.css',
  //       '/index.css',
  //     ]))
  //     .then(() => self.skipWaiting())
  // );
});

// Activate: clean old caches
self.addEventListener('activate', (event) => {
  console.log(event);
  self.skipWaiting();
  event.waitUntil(
    self.clients.claim()
  );
  // event.waitUntil(
  //   caches.keys().then(keys =>
  //     Promise.all(
  //       keys
  //         .filter(key => key !== 'jmeu')
  //         .map(key => caches.delete(key))
  //     )
  //   ).then(() => self.clients.claim())
  // );
});

self.addEventListener('fetch', event => {
  console.log(event);

  event.respondWith(
    fetch(event.request).then(response => {
        caches.open('jmeu').then(cache => {
          event.waitUntil(cache.put(event.request, response.clone()));
        });
        return response;
      }).catch(e => {
        console.log(e);
        return caches.match(event.request)
      })
  );
});

self.addEventListener("sync", (event) => {
  console.log(event);
  if (event.tag === "sync-messages") {
    // event.waitUntil(sendOutboxMessages());
  }
});
