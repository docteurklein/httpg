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
    let body = event.data.json();
    console.log(body);
    event.waitUntil(
      self.registration.showNotification(body.title, {
        body: body.content
      })
    );
  }
});
