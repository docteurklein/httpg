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
  event.waitUntil(
    clients
      .openWindow(self.location.origin)
      .then(windowClient => windowClient.focus())
  );
});
