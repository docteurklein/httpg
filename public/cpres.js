navigator.serviceWorker.register('/service-worker.js').then(reg => {
  reg.update();
});

function store_push_endpoint() {
  navigator.serviceWorker.ready
    .then(function(registration) {
      return registration.pushManager.getSubscription().then(async function(subscription) {
        if (subscription) {
          return subscription;
        }
        return registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: 'BARWc1gwXxHnUlh2vw1o2TFlWC-qjccHZ8y3cIOE5DDePt4TNOGChCM64PP7kiuGgmnV082Nagdd3juNKmb2f18',
        });
      });
    })
    .then(async subscription => {
      Array.from(document.querySelectorAll('input.push_endpoint')).forEach(i => {
        if (!i.value) {
          i.value = JSON.stringify(subscription);
        }
      });
    })
  ;
}

navigator.permissions
  .query({ name: 'notifications' })
  .then((status) => {
    if (status.state === 'granted') {
      store_push_endpoint();
    }
    status.onchange = (e) => {
      if (e.target.state === 'granted') {
        store_push_endpoint();
      }
    };
  })
;

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

