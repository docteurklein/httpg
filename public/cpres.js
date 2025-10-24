navigator.geolocation.getCurrentPosition(
  pos => {
    let i = document.querySelector('.new input.location');
    if (i) {
      i.value = `(${pos.coords.latitude},${pos.coords.longitude})`;
    }
  }
);
