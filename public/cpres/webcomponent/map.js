import L, {Map, Marker, TileLayer, ImageOverlay, GeoJSON} from 'https://unpkg.com/leaflet@2.0.0-alpha.1/dist/leaflet.js';

import 'https://cdn.jsdelivr.net/gh/Falke-Design/Leaflet-V1-polyfill/leaflet-v1-polyfill.js';

applyAllPolyfills();

import {} from 'https://unpkg.com/Leaflet.markercluster@1.5.3/dist/leaflet.markercluster-src.js';


class IsMap extends HTMLInputElement {
  static formAssociated = true;
  constructor() {
    super();

    this.features = {};

    this.div = document.createElement('div');
    this.map = new Map(this.div, {
      // maxBounds: this.dataset.bounds
    });
  }

  connectedCallback() {
    this.insertAdjacentElement('afterend', this.div);
    this.marker = new Marker([0, 0]).addTo(this.map);

    const tiles = new TileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>'
    }).addTo(this.map);

    this.map.setZoom(1);

    if (!this.value) {
      this.map.locate({
        setView: true
      });
    }

    let matches = this.value.match(/\((.*),(.*)\)/);
    if (matches && matches.length > 1) {
      let pos = [matches[1], matches[2]];
      this.marker.setLatLng(pos);
      this.map.setView(pos);
      this.map.setZoom(9);
    }

    if (!this.readOnly) {
      this.map.on('click', e => {
        this.marker.setLatLng([e.latlng.lat, e.latlng.lng]);
        this.value = `(${e.latlng.lat},${e.latlng.lng})`;
      });
    }

    this.geojson(JSON.parse(this.dataset.geojson));

    this.type = 'hidden'; // progressive enhancement
  }

  geojson(data) {
    new GeoJSON(data, {
      style(feature) {
          return feature.properties.style || {};
      },
      onEachFeature: (feature, layer) => {
        this.features[feature.properties.id] = layer;

        if (feature.properties.popup) {
          layer.bindPopup(feature.properties.popup, {
            maxHeight: 400,
            maxWidth: 1000,
            minWidth: 300,
          });
        }
        if (feature.properties.tooltip) {
          layer.bindTooltip(feature.properties.tooltip, {
          });
        }
        if (feature.properties.group) {
          if (!this[feature.properties.group]) {
            this[feature.properties.group] = L.markerClusterGroup({});
            this.map.addLayer(this[feature.properties.group]);
          }
          this[feature.properties.group].addLayer(layer);
        }
        else {
          this.map.addLayer(layer);
        }
      }
    });
  }

  on(event, f) {
    this.map.on(event, f);
  }

  onGroup(group, event, f) {
    this[group].on(event, f);
  }

  removeGroup(group) {
    if (group in this) {
      this.map.removeLayer(this[group]);
      delete this[group];
    }
  }
  
  openPopup(id) {
    this.features[id].__parent.spiderfy();
    this.features[id].openPopup();
  }

  setView(pos) {
    this.map.setView(pos, 16);
  }
}

customElements.define("cpres-map", IsMap, { extends: "input" });
