import L, {Map, TileLayer, ImageOverlay, GeoJSON} from 'https://unpkg.com/leaflet@2.0.0-alpha.1/dist/leaflet.js';

import 'https://cdn.jsdelivr.net/gh/Falke-Design/Leaflet-V1-polyfill/leaflet-v1-polyfill.js';

applyAllPolyfills();
// applyDomUtilPolyfill();
// applyUtilPolyfill();
// applyFactoryMethodsPolyfill();

import {} from 'https://unpkg.com/Leaflet.markercluster@1.5.3/dist/leaflet.markercluster-src.js';

const map = new Map('map');

map.on('locationfound', (event) => {
  // let params = new URLSearchParams(window.location.search);
  // params.set('sql', `select coalesce(jsonb_agg(geojson)::text, '[]') from cpres.nearby where bird_distance_km < $1::double precision`);
  // params.append('location', `(${event.latlng.lat},${event.latlng.lng})`);
  // params.append('params[]', '5000');
  // fetch(`/query?${params}`, {
  //   headers: {
  //     'accept': 'application/json'
  //   }
  // })
  //   .then(res => res.json())
  //   .then(function(data) {
      let data = [...document.querySelectorAll('[data-geojson]')].map(node => {
        let geojson = JSON.parse(node.getAttribute('data-geojson'));
        geojson.properties.description = node.innerHTML;
        return geojson;
      });
      var markers = L.markerClusterGroup({});
      new GeoJSON(data, {
        onEachFeature(feature, layer) {
          layer.bindPopup(feature.properties.description, {
            maxWidth: 1000,
          });
    			markers.addLayer(layer);
        }
      });//.addTo(map);
      map.setZoom(12);
      map.addLayer(markers);
    // })
  // ;
});

map.locate({
    setView: true
});

const tiles = new TileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>'
}).addTo(map);
