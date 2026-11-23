self.addEventListener('install', (event) => {
  console.log(event);
  self.skipWaiting();
  event.waitUntil(
    caches.open('jmeu')
      .then(cache => cache.addAll([
        '/jmeu/query?sql=select%20%2A%20from%20jmeu.head%20union%20all%20select%20body::text%20from%20jmeu.admin_html',
        '/jmeu/query?sql=select%20%2A%20from%20jmeu.head%20union%20all%20select%20body::text%20from%20jmeu.agneulage_html',
        '/jmeu/query?sql=select%20%2A%20from%20jmeu.head%20union%20all%20select%20body::text%20from%20jmeu.treatment_html',
        '/jmeu/query?sql=select%20%2A%20from%20jmeu.head%20union%20all%20select%20body::text%20from%20jmeu.medication_html',
        '/jmeu/query?sql=select%20%2A%20from%20jmeu.head',
        '/jmeu/',
        '/jmeu/index.css',
        '/index.css',
      ]))
      .then(() => self.skipWaiting())
  );
});

// Activate: clean old caches
self.addEventListener('activate', (event) => {
  console.log(event);
  self.skipWaiting();
  event.waitUntil(
    self.clients.claim()
  );
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys
          .filter(key => key !== 'jmeu')
          .map(key => caches.delete(key))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  console.log(event);

  event.respondWith(
    fetch(event.request).then(response => {
        console.log(response);
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

// self.addEventListener("sync", (event) => {
//   console.log(event);
//   if (event.tag === "sync-messages") {
//     // event.waitUntil(sendOutboxMessages());
//   }
// });
