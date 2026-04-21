import imageCompression from 'https://esm.run/browser-image-compression@2.0.1';
// import {default as photon_init} from 'https://cdn.jsdelivr.net/npm/@silvia-odwyer/photon/+esm';

navigator.serviceWorker && navigator.serviceWorker.register('/cpres/service-worker.js').then(reg => {
  reg.update();
});

function store_push_endpoint() {
  navigator.serviceWorker.ready
    .then(function(registration) {
      return registration.pushManager.getSubscription().then(async function(subscription) {
        if (subscription) {
          return subscription;
        }
        return registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: 'BARWc1gwXxHnUlh2vw1o2TFlWC-qjccHZ8y3cIOE5DDePt4TNOGChCM64PP7kiuGgmnV082Nagdd3juNKmb2f18',
        });
      });
    })
    .then(async subscription => {
      Array.from(document.querySelectorAll('input.push_endpoint')).forEach(i => {
        if (!i.value) {
          i.value = JSON.stringify(subscription);
        }
      });
    })
  ;
}

navigator.permissions
  .query({ name: 'notifications' })
  .then((status) => {
    if (status.state === 'granted') {
      store_push_endpoint();
    }
    status.onchange = (e) => {
      if (e.target.state === 'granted') {
        store_push_endpoint();
      }
    };
  })
;

navigator.geolocation.getCurrentPosition(async pos => {
  let location = `(${pos.coords.latitude},${pos.coords.longitude})`;

  Array.from(document.querySelectorAll('input.location')).forEach(i => {
    if (!i.value) {
      i.value = location
    }
  });
});

Array.from(document.querySelectorAll('.inline-name')).forEach(e => e.addEventListener('input', (e => {
  e.target.size = Math.max(4, e.target.value.length);
})));

Array.from(document.querySelectorAll('.messages')).forEach(e => {
  e.scrollTop = e.scrollHeight;
});

document.addEventListener('submit', async event => {
  let formData = new FormData(event.target);
  if (formData.has('file') && formData.get('file').type.startsWith('image/')) {
    event.preventDefault();

    formData.set('file', await imageCompression(formData.get('file'), {
      maxSizeMB: 0.5,
      maxIteration: 20,
      maxWidthOrHeight: 1800,
      useWebWorker: true,
    }), formData.get('file').name);

    // let canvas = document.createElement('canvas');
    // document.body.appendChild(canvas);
    // canvas.width = 1080;
    // canvas.height = 768;

    // let ctx = canvas.getContext('2d');
    // ctx.drawImage(await createImageBitmap(formData.get('file')), 0, 0);

    // let photon = await photon_init();

    // let photon_img = photon.open_image(canvas, ctx);
    // let newcanvas = photon.resize_img_browser(photon_img, 360, 239, 1);
    // // let newcanvas = photon_img.resize

    // const blob = await new Promise(resolve => newcanvas.toBlob(resolve));
    // formData.set('file', blob, formData.get('file').name);

    fetch(event.target.action, {
      method: 'POST',
      headers: {
        'Accept': 'text/html',
      },
      body: formData,
    })
    .then(response => response.text())
    .then(result => {
      let parser = new DOMParser();
      let doc = parser.parseFromString(result, 'text/html');
      document.replaceChild(doc.documentElement, document.documentElement);
    });
  }
});

document.addEventListener('click', (event) => {
  if (event.target.className !== 'marker-icon') {
    return;
  }
  event.preventDefault();
  window.map?.openPopup(event.target.getAttribute('for'));
  window.map?.parentNode.scrollIntoView();
});

window.map?.on('popupopen', event => {
  window.map.setAttribute('data-target', event.popup._source.feature.id);
  window.map.dispatchEvent(new InputEvent('input'));
});


document.addEventListener('DOMContentLoaded', () => {
  let loc = new URL(window.location.href);
  window.map?.addEventListener('input', e => {
    let href = new URL(window.map.getAttribute('href'), window.location.href);

    href.searchParams.set('location', window.map.value);
    href.searchParams.set('target', window.map.getAttribute('data-target') || '');
    fetch(href.toString(), {
      headers: {
        'Accept': 'application/json'
      }
    })
      .then(response => response.json())
      .then((geojson) => {
        window.map.removeGroup('route');
        window.map.geojson(geojson);
      })
    ;
  });
});
