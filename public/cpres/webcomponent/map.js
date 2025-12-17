import L, {Map, Marker, TileLayer, ImageOverlay, GeoJSON} from 'https://unpkg.com/leaflet@2.0.0-alpha.1/dist/leaflet.js';

import 'https://cdn.jsdelivr.net/gh/Falke-Design/Leaflet-V1-polyfill/leaflet-v1-polyfill.js';

applyAllPolyfills();

import {} from 'https://unpkg.com/Leaflet.markercluster@1.5.3/dist/leaflet.markercluster-src.js';


class IsMap extends HTMLInputElement {
  constructor() {
    super();
  }

  connectedCallback() {
    this.div = document.createElement('div');

    this.type = 'hidden';

    this.insertAdjacentElement('afterend', this.div);
    this.map = new Map(this.div);
    this.map.setZoom(1);

    if (!this.value) {
      this.map.locate({
        setView: true
      });
    }

    let pos = [0, 0];
    let matches = this.value.match(/\((.*),(.*)\)/);
    if (matches && matches.length > 1) {
      pos = [matches[1], matches[2]];
      this.map.setZoom(9);
    }
    this.map.setView(pos);
    this.marker = new Marker(pos).addTo(this.map);

    if (!this.readOnly) {
      this.map.on('click', e => {
        this.marker.setLatLng([e.latlng.lat, e.latlng.lng]);
        this.value = `(${e.latlng.lat},${e.latlng.lng})`;
      });
    }

    const tiles = new TileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>'
    }).addTo(this.map);
  }
}

customElements.define("cpres-map", IsMap, { extends: "input" });
