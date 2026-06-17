if (window.map?.getAttribute('geolocate') === 'watch') {
  let lock = await navigator.wakeLock?.request('screen').catch(console.log);
  lock.onrelease = console.log;

  document.addEventListener("visibilitychange", async (e) => {
    if (lock !== null && document.visibilityState === "visible") {
      lock = await navigator.wakeLock?.request("screen");
      lock.onrelease = console.log;
    }
  });
}

const qs = new URLSearchParams(window.location.search);

window.map?.addEventListener('input', (event) => {
  if (event.target.readOnly) {
    return;
  }
  fetch(event.target.getAttribute('href'), {
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    },
    method: 'POST',
    body: JSON.stringify({
      params: [
        qs.get('run_id'),
        event.target.value,
      ],
    }),
  })
    .catch(e => {
      console.log(e);
      // localStorage.setItem('')
    })
    .then(response => response.json())
    .then((geojson) => {
      window.map?.geojson(geojson);
    })
  ;
});
