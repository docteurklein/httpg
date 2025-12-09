navigator.geolocation.getCurrentPosition(
  pos => {
    let i = document.querySelector('.new input.location');
    if (i) {
      i.value = `(${pos.coords.latitude},${pos.coords.longitude})`;
    }
  }
);

navigator.serviceWorker.register('/service-worker.js?v=1');

navigator.serviceWorker.ready.then(function(registration) {
  registration.update();
  return registration.pushManager.getSubscription().then(async function(subscription) {
    if (subscription) {
      return subscription;
    }
    return registration.pushManager.subscribe();
  });
}).then(async subscription => {
  await fetch('/query', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      sql: `
        insert into cpres.person_detail (push_endpoint) values ($1)
        on conflict (person_id) do update
        set push_endpoint = excluded.push_endpoint
      `,
      params: [subscription.endpoint],
    })
  })
});
