import L, {Map, Icon, Popup, Tooltip, Marker, LayerGroup, TileLayer, GeoJSON} from 'https://unpkg.com/leaflet@2.0.0-alpha.1/dist/leaflet.js';

import 'https://cdn.jsdelivr.net/gh/Falke-Design/Leaflet-V1-polyfill/leaflet-v1-polyfill.js';

applyAllPolyfills();

import {} from 'https://unpkg.com/Leaflet.markercluster@1.5.3/dist/leaflet.markercluster-src.js';


class IsMap extends HTMLInputElement {
  static formAssociated = true;
  static observedAttributes = ['data-geojson','data-zoom', 'value'];

  constructor() {
    super();

    this.features = {};
    this.groups = {};

    this.is_inited = false;
  }

  connectedCallback() {
    if (!this.is_inited) {
      this.init();
    }
  }

  init() {
    this.div = document.createElement('div');
    this.insertAdjacentElement('afterend', this.div);

    this.map = new Map(this.div, {
      maxBounds: this.dataset.bounds
    });

    this.defaultGroup = new LayerGroup([]);
    this.map.addLayer(this.defaultGroup);

    let qs = new URLSearchParams(window.location.search);
    this.map.setZoom(qs.get('zoom') || 9);

    this.marker = new Marker([0, 0], {
      icon: new Icon({
        iconUrl: this.dataset.markerUrl || 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png',
        iconSize: [25, 41],
        iconAnchor: [12, 30],
      }),
    }).addTo(this.map);

    if (this.getAttribute('geolocate') === 'watch') {
      navigator.geolocation.watchPosition(async pos => {
        let location = `(${pos.coords.latitude},${pos.coords.longitude})`;

        this.value = location;
      }, console.log, {
        enableHighAccuracy: true,
      });
    }

    if (this.getAttribute('geolocate') === 'init') {
      navigator.geolocation.getCurrentPosition(async pos => {
        let location = `(${pos.coords.latitude},${pos.coords.longitude})`;

        if (!this.value) {
          this.value = location;
        }
      }, console.log, {
        enableHighAccuracy: true,
      });
    }

    if (!this.value) {
      this.map.locate({
        setView: true
      });
    }

    if (!this.readOnly) {
      this.map.on('click', e => {
        this.value = `(${e.latlng.lat},${e.latlng.lng})`;
      });
    }

    new TileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>',
    }).addTo(this.map);

    new TileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', {
      maxZoom: 19,
      attribution: 'ArcGis',
      opacity: .4,
    }).addTo(this.map);

    this.type = 'hidden'; // progressive enhancement

    this.is_inited = true;
  }

  attributeChangedCallback(name, oldValue, newValue) {
    if (!this.is_inited) {
      this.init();
    }
    if (name === 'data-zoom' && newValue) {
        this.map.setZoom(this.dataset.zoom);
    }

    if (name === 'value' && newValue && oldValue != newValue) {
      let matches = newValue.match(/\((.*),(.*)\)/);
      if (matches && matches.length > 1) {
        let pos = [matches[1], matches[2]];
        this.map.setView(pos);
        this.marker.setLatLng(pos);
      }

      this.dispatchEvent(new InputEvent('input'));
    }

    if (name === 'data-geojson' && newValue) {
        this.geojson(JSON.parse(this.dataset.geojson));
    }
  }

  geojson(data) {
    new GeoJSON(data, {
      style(feature) {
          // let colors = ['green', 'yellow', 'red', 'blue', 'purple', 'black', 'orange', 'grey'];
          // let c = colors[Math.floor(Math.random() * colors.length)];
          // return {color: c};
          return feature.properties?.style || {};
      },
      onEachFeature: (feature, layer) => {
        if (feature.id in this.features) {
          return;
        }
        if (feature.id) {
          this.features[feature.id] = layer;
        }

        if (feature.properties?.popup) {
          layer.bindPopup(new Popup(feature.properties.popup, layer));
        }
        if (feature.properties?.tooltip) {
          layer.bindTooltip(new Tooltip(feature.properties.tooltip, layer));
        }

        if (feature.properties?.group) {
          if (!this.groups[feature.properties.group]) {
            this.groups[feature.properties.group] = L.markerClusterGroup({});
            this.map.addLayer(this.groups[feature.properties.group]);
          }
          this.groups[feature.properties.group].addLayer(layer);
        }        
        else {
          this.defaultGroup.addLayer(layer);
        }
      }
    });
  }

  on(event, f) {
    this.map.on(event, f);
  }

  openPopup(id) {
    if (this.features[id].__parent?.spiderify) {
      this.features[id].__parent.spiderfy();
    }
    this.features[id].openPopup();
  }

  removeGroup(group) {
    if (group in this.groups) {
      this.map.removeLayer(this.groups[group]);
      delete this.groups[group];
    }
  }

  on(event, fn) {
    this.map.on(event, fn);
  }
}

customElements.define('cpres-map', IsMap, { extends: 'input' });
