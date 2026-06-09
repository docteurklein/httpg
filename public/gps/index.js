
const qs = new URLSearchParams(window.location.search);

window.map?.addEventListener('input', (event) => {
  if (event.target.getAttribute('is') !== 'cpres-map') {
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
    .then(response => response.json())
    .then((geojson) => {
      // window.map.removeGroup('route');
      window.map?.geojson(geojson);
    })
  ;
});
