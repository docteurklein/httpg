import L, {Map, TileLayer, ImageOverlay, GeoJSON} from 'https://unpkg.com/leaflet@2.0.0-alpha.1/dist/leaflet.js';

const map = new Map('map');

map.on('locationfound', (event) => {
  let params = new URLSearchParams();
  params.append('location', `(${event.latlng.lat},${event.latlng.lng})`);
  fetch(`/query?sql=select coalesce(jsonb_agg(geojson)::text, '[]') from cpres.nearby&${params}`)
    .then(res => res.json())
    .then(function(data) {
      new GeoJSON(data, {
        onEachFeature(feature, layer) {
          layer.bindPopup(feature.properties.description, {
            maxHeight: 250
          });
        }
      }).addTo(map)
      map.setZoom(12);
    })
  ;
});

map.locate({
    setView: true
});

const tiles = new TileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>'
}).addTo(map);
