self.addEventListener('push', function(event) {
  console.log(event);
  event.waitUntil(
    self.registration.showNotification('cpres', {
      body: event.data.text(),
    })
  );
});
