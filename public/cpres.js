
// window.name = 'cpres';

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

// navigator.serviceWorker.register('/service-worker.js?v=1');

// navigator.serviceWorker.ready.then(function(registration) {
//   registration.update();
//   return registration.pushManager.getSubscription().then(async function(subscription) {
//     if (subscription) {
//       return subscription;
//     }
//     return registration.pushManager.subscribe();
//   });
// }).then(async subscription => {
//   await fetch('/query', {
//     method: 'POST',
//     headers: {
//       'Content-Type': 'application/json',
//     },
//     body: JSON.stringify({
//       sql: `
//         insert into cpres.person_detail (push_endpoint) values ($1)
//         on conflict (person_id) do update
//         set push_endpoint = excluded.push_endpoint
//       `,
//       params: [subscription.endpoint],
//     })
//   })
// });
