navigator.geolocation.getCurrentPosition(
  pos => {
    let i = document.querySelector('.new input.location');
    if (i) {
      i.value = `(${pos.coords.latitude},${pos.coords.longitude})`;
    }
  }
);

console.log(navigator.serviceWorker.register('/service-worker.js?v=1'));

console.log(navigator.serviceWorker);
navigator.serviceWorker.ready
.then(function(registration) {
  console.log(registration);
  registration.update();
  // Use the PushManager to get the user's subscription to the push service.
  return registration.pushManager.getSubscription()
  .then(async function(subscription) {
    // If a subscription was found, return it.
    console.log(subscription);
    if (subscription) {
      return subscription;
    }

    // // Get the server's public key
    // const response = await fetch('./vapidPublicKey');
    // const vapidPublicKey = await response.text();
    // // Chrome doesn't accept the base64-encoded (string) vapidPublicKey yet
    // // urlBase64ToUint8Array() is defined in /tools.js
    // const convertedVapidKey = urlBase64ToUint8Array(vapidPublicKey);

    // // Otherwise, subscribe the user (userVisibleOnly allows to specify that we don't plan to
    // // send notifications that don't have a visible effect for the user).
    return registration.pushManager.subscribe();
  });
}).then(console.log);
