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
        body: payload.content,
        data: {
          path: payload.path
        }
      })
    );
  }
});

self.addEventListener('notificationclick', event => {
  console.log(event, event.notification.data);
  event.waitUntil(
    self.clients
      .openWindow(new URL(event.notification.data.path, self.location.origin).toString())
      .then(w => w.focus())
  );
});
