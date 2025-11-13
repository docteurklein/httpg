import L, {Map, TileLayer, ImageOverlay, GeoJSON} from 'https://unpkg.com/leaflet@2.0.0-alpha.1/dist/leaflet.js';

import 'https://cdn.jsdelivr.net/gh/Falke-Design/Leaflet-V1-polyfill/leaflet-v1-polyfill.js';

applyAllPolyfills();
// applyDomUtilPolyfill();
// applyUtilPolyfill();
// applyFactoryMethodsPolyfill();

import {} from 'https://unpkg.com/Leaflet.markercluster@1.5.3/dist/leaflet.markercluster-src.js';

const map = new Map('map');

map.on('locationfound', (event) => {
  let params = new URLSearchParams();
  params.append('location', `(${event.latlng.lat},${event.latlng.lng})`);
  fetch(`/query?sql=select coalesce(jsonb_agg(geojson)::text, '[]') from cpres.nearby&${params}`, {
    headers: {
      'accept': 'application/json'
    }
  })
    .then(res => res.json())
    .then(function(data) {
      var markers = L.markerClusterGroup({
        // disableClusteringAtZoom: 17,
        // spiderfyOnMaxZoom: true,
        // animate: false,
        // spiderfyDistanceMultiplier: 10,
        // spiderfyShapePositions: function(count, centerPt) {
        //   var distanceFromCenter = 35,
        //       markerDistance = 45,
        //       lineLength = markerDistance * (count - 1),
        //       lineStart = centerPt.y - lineLength / 2,
        //       res = [],
        //       i;

        //   res.length = count;

        //   for (i = count - 1; i >= 0; i--) {
        //       res[i] = new Point(centerPt.x + distanceFromCenter, lineStart + markerDistance * i);
        //   }

        //   return res;
        // }
      });
      new GeoJSON(data, {
        onEachFeature(feature, layer) {
          layer.bindPopup(feature.properties.description, {
            maxHeight: 250
          });
    			markers.addLayer(layer);
        }
      });//.addTo(map);
      map.setZoom(12);
      map.addLayer(markers);
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
