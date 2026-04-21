import L, {Map, Icon, Popup, Marker, TileLayer, ImageOverlay, GeoJSON} from 'https://unpkg.com/leaflet@2.0.0-alpha.1/dist/leaflet.js';

import 'https://cdn.jsdelivr.net/gh/Falke-Design/Leaflet-V1-polyfill/leaflet-v1-polyfill.js';

applyAllPolyfills();

import {} from 'https://unpkg.com/Leaflet.markercluster@1.5.3/dist/leaflet.markercluster-src.js';


class IsMap extends HTMLInputElement {
  static formAssociated = true;
  static observedAttributes = ['data-geojson','data-zoom'];

  constructor() {
    super();

    this.features = {};
    this.groups = {};

    this.div = document.createElement('div');
    this.map = new Map(this.div, {
      maxBounds: this.dataset.bounds
    });
    this.group = L.markerClusterGroup({});
    this.map.addLayer(this.group);
  }

  connectedCallback() {
    this.insertAdjacentElement('afterend', this.div);
    this.marker = new Marker([0, 0], {
      icon: new Icon({
        iconUrl: this.dataset.markerUrl || 'https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png',
        iconSize: [25, 41],
        iconAnchor: [12, 30],
      }),
    }).addTo(this.map);

    new TileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="http://www.openstreetmap.org/copyright">OpenStreetMap</a>',
    }).addTo(this.map);

    new TileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', {
      maxZoom: 19,
      attribution: 'ArcGis',
      opacity: .5,
    }).addTo(this.map);

    let loc = new URL(window.location.href);
    this.map.setZoom(loc.searchParams.get('zoom') || 9);

    this.map.on('zoomend', () => {
      let loc = new URL(window.location.href);
      loc.searchParams.set('zoom', this.map.getZoom());
      history.replaceState({}, "", loc);
    });

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
    }

    if (!this.readOnly) {
      this.map.on('click', e => {
        this.marker.setLatLng([e.latlng.lat, e.latlng.lng]);
        this.value = `(${e.latlng.lat},${e.latlng.lng})`;
        this.dispatchEvent(new InputEvent('input'));
      });
    }

    this.type = 'hidden'; // progressive enhancement
  }

  attributeChangedCallback(name, oldValue, newValue) {
    if (name === 'data-geojson' && newValue) {
        this.geojson(JSON.parse(this.dataset.geojson));
    }
    if (name === 'data-zoom' && newValue) {
        this.map.setZoom(this.dataset.zoom);
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
          layer.bindPopup(new Popup({
            content: feature.properties.popup,
            maxHeight: 300,
            // maxWidth: 1000,
            minWidth: 200,
            autoClose: false,
            closeOnClick: false,
          }, layer));
        }
        if (feature.properties?.tooltip) {
          layer.bindTooltip(feature.properties.tooltip);
        }

        if (feature.properties?.group) {
          if (!this.groups[feature.properties.group]) {
            this.groups[feature.properties.group] = L.markerClusterGroup({});
            this.map.addLayer(this.groups[feature.properties.group]);
          }
          this.groups[feature.properties.group].addLayer(layer);
        }        
        else {
          this.group.addLayer(layer);
        }
      }
    });
  }

  on(event, f) {
    this.map.on(event, f);
  }

  openPopup(id) {
    this.features[id].__parent.spiderfy();
    this.features[id].openPopup();
  }

  removeGroup(group) {
    if (group in this.groups) {
      this.map.removeLayer(this.groups[group]);
      delete this.groups[group];
    }
  }
}

customElements.define("cpres-map", IsMap, { extends: "input" });
