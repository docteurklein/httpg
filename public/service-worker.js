self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  self.skipWaiting();
  event.waitUntil(
    self.clients.claim()
  );
});

self.addEventListener('push', function(event) {
  console.log(event);
  if (event.data) {
    let payload = event.data.json();
    console.log(payload);
    event.waitUntil(
      self.registration.showNotification(payload.title, payload.content && {
        body: payload.content
      })
    );
  }
});

self.addEventListener('notificationclick', event => {
  const rootUrl = new URL('/', location).href;
  event.notification.close();
  event.waitUntil(
    clients.matchAll().then(matchedClients => {
      for (let client of matchedClients) {
        if (client.url === rootUrl) {
          return client.focus();
        }
      }
      return clients.openWindow("/");
    })
  );
});
