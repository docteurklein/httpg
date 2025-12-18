navigator.serviceWorker.register('/service-worker.js?v=1');

navigator.serviceWorker.ready.then(function(registration) {
  // registration.update();
  return registration.pushManager.getSubscription().then(async function(subscription) {
    if (subscription) {
      return subscription;
    }
    return registration.pushManager.subscribe();
  });
}).then(async subscription => {
  Array.from(document.querySelectorAll('input.push_endpoint')).forEach(i => {
    if (!i.value) {
      i.value = subscription.endpoint;
    }
  });
});

navigator.geolocation.getCurrentPosition(async pos => {
  let location = `(${pos.coords.latitude},${pos.coords.longitude})`;

  Array.from(document.querySelectorAll('input.location')).forEach(i => {
    if (!i.value) {
      i.value = location
    }
  });
});

Array.from(document.querySelectorAll('.inline-name')).forEach(e => e.addEventListener('input', (e => {
  e.target.size = Math.max(4, e.target.value.length);
})));

Array.from(document.querySelectorAll('.messages')).forEach(e => {
  e.scrollTop = e.scrollHeight;
});

