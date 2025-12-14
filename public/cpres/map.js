import L, {Map, TileLayer, ImageOverlay, GeoJSON} from 'https://unpkg.com/leaflet@2.0.0-alpha.1/dist/leaflet.js';

import 'https://cdn.jsdelivr.net/gh/Falke-Design/Leaflet-V1-polyfill/leaflet-v1-polyfill.js';

applyAllPolyfills();

import {} from 'https://unpkg.com/Leaflet.markercluster@1.5.3/dist/leaflet.markercluster-src.js';

const map = new Map('map');

let data = [...document.querySelectorAll('[data-geojson]')].map(node => {
  let geojson = JSON.parse(node.getAttribute('data-geojson'));
  geojson.properties.description = node.innerHTML;
  return geojson;
});
var markers = L.markerClusterGroup({});
new GeoJSON(data, {
  onEachFeature(feature, layer) {
    layer.bindPopup(feature.properties.description, {
      maxHeight: 400,
      maxWidth: 1000,
      minWidth: 300,
    });
		markers.addLayer(layer);
  }
});
map.setZoom(12);
map.addLayer(markers);

map.locate({
  setView: true
});

const tiles = new TileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 19,
  attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>'
}).addTo(map);
