// Builds an RTMP/RTSP/SRT stream URL from the form fields and renders it as a QR code.
// URL shapes follow tak-video-restreamer's conventions:
//   rtsp://SERVER:8554/{stream_name}
//   srt://SERVER:8890?streamid=read:{stream_name}[&passphrase=...]
//   rtmp://SERVER:1935/{stream_name}
(function () {
  "use strict";

  var DEFAULT_PORTS = { rtsp: 8554, rtmp: 1935, srt: 8890 };

  var form = document.getElementById("stream-form");
  var addressInput = document.getElementById("address");
  var portInput = document.getElementById("port");
  var portHint = document.getElementById("port-hint");
  var pathInput = document.getElementById("path");
  var srtModeField = document.getElementById("srt-mode-field");
  var srtModeSelect = document.getElementById("srt-mode");
  var passphraseField = document.getElementById("passphrase-field");
  var passphraseInput = document.getElementById("passphrase");
  var streamUrlInput = document.getElementById("stream-url");
  var copyBtn = document.getElementById("copy-btn");
  var qrContainer = document.getElementById("qr-code");
  var downloadBtn = document.getElementById("download-qr-btn");

  var portTouched = false;
  var STORAGE_KEY = "restreamerQr:v1";

  function currentProtocol() {
    var checked = form.querySelector('input[name="protocol"]:checked');
    return checked ? checked.value : "rtsp";
  }

  // Infra-TAK gives this page its own "qr.<fqdn>" subdomain and the video
  // restreamer its own "stream.<fqdn>" one (see SERVICE_DOMAIN_DEFAULTS in
  // the infra-TAK console). Guessing the restreamer's address from the
  // page's own hostname means a fresh visit needs zero typing to get a
  // working default.
  function guessDefaultAddress() {
    var parts = window.location.hostname.split(".");
    if (parts.length > 1 && parts[0] === "qr") {
      return ["stream"].concat(parts.slice(1)).join(".");
    }
    return "";
  }

  function loadSaved() {
    try {
      return JSON.parse(window.localStorage.getItem(STORAGE_KEY) || "{}");
    } catch (e) {
      return {};
    }
  }

  function saveState() {
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify({
        protocol: currentProtocol(),
        address: addressInput.value,
        port: portInput.value,
        portTouched: portTouched,
        path: pathInput.value,
        srtMode: srtModeSelect.value,
        passphrase: passphraseInput.value
      }));
    } catch (e) {
      // localStorage unavailable (private browsing, quota) — not persisting
      // between visits is a minor inconvenience, not worth surfacing.
    }
  }

  // Restores whatever was filled in on the last visit — repeat use (the
  // common case: same restreamer, new camera each time) then needs only the
  // path field touched, not every field retyped.
  function restoreState() {
    var saved = loadSaved();
    if (saved.protocol) {
      var radio = form.querySelector('input[name="protocol"][value="' + saved.protocol + '"]');
      if (radio) radio.checked = true;
    }
    if (saved.address) {
      addressInput.value = saved.address;
    } else {
      var guess = guessDefaultAddress();
      if (guess) addressInput.value = guess;
    }
    if (saved.portTouched && saved.port) {
      portInput.value = saved.port;
      portTouched = true;
    }
    if (saved.path) pathInput.value = saved.path;
    if (saved.srtMode) srtModeSelect.value = saved.srtMode;
    if (saved.passphrase) passphraseInput.value = saved.passphrase;
  }

  function applyProtocolDefaults() {
    var protocol = currentProtocol();

    if (!portTouched) {
      portInput.value = DEFAULT_PORTS[protocol];
    }
    portHint.textContent = "Default for " + protocol.toUpperCase() + " is " + DEFAULT_PORTS[protocol] + ".";

    var isSrt = protocol === "srt";
    srtModeField.hidden = !isSrt;
    passphraseField.hidden = !isSrt;
  }

  function sanitizePath(raw) {
    return raw.trim().replace(/^\/+/, "").replace(/\s+/g, "");
  }

  function buildStreamUrl() {
    var protocol = currentProtocol();
    var address = addressInput.value.trim();
    var port = portInput.value.trim();
    var streamName = sanitizePath(pathInput.value);

    if (!address || !port || !streamName) {
      return "";
    }

    if (protocol === "srt") {
      var mode = srtModeSelect.value;
      var url = "srt://" + address + ":" + port + "?streamid=" + mode + ":" + streamName;
      var passphrase = passphraseInput.value.trim();
      if (passphrase) {
        url += "&passphrase=" + encodeURIComponent(passphrase);
      }
      return url;
    }

    // rtsp and rtmp both use address:port/path
    return protocol + "://" + address + ":" + port + "/" + streamName;
  }

  function renderQr(text) {
    qrContainer.innerHTML = "";

    if (!text) {
      var placeholder = document.createElement("p");
      placeholder.className = "qr-placeholder";
      placeholder.textContent = "Fill in the server address, port, and path to generate a QR code.";
      qrContainer.appendChild(placeholder);
      downloadBtn.hidden = true;
      return;
    }

    // "Q" (25% error correction) over the default "M" — this QR is often
    // scanned straight off a phone or laptop screen rather than print, where
    // glare and moire cost more resolution than a denser code loses.
    var qr = qrcode(0, "Q");
    qr.addData(text);
    qr.make();
    qrContainer.innerHTML = qr.createSvgTag(7, 8);
    downloadBtn.hidden = false;
  }

  function update() {
    applyProtocolDefaults();
    var url = buildStreamUrl();
    streamUrlInput.value = url;
    renderQr(url);
    saveState();
  }

  function svgToPngDataUrl(svgEl, callback) {
    var serializer = new XMLSerializer();
    var svgString = serializer.serializeToString(svgEl);
    var svgBlob = new Blob([svgString], { type: "image/svg+xml;charset=utf-8" });
    var url = URL.createObjectURL(svgBlob);

    var img = new Image();
    img.onload = function () {
      var canvas = document.createElement("canvas");
      var size = 512;
      canvas.width = size;
      canvas.height = size;
      var ctx = canvas.getContext("2d");
      ctx.fillStyle = "#ffffff";
      ctx.fillRect(0, 0, size, size);
      ctx.drawImage(img, 0, 0, size, size);
      URL.revokeObjectURL(url);
      callback(canvas.toDataURL("image/png"));
    };
    img.src = url;
  }

  copyBtn.addEventListener("click", function () {
    if (!streamUrlInput.value) return;
    navigator.clipboard.writeText(streamUrlInput.value).then(function () {
      copyBtn.textContent = "Copied";
      copyBtn.classList.add("copied");
      setTimeout(function () {
        copyBtn.textContent = "Copy";
        copyBtn.classList.remove("copied");
      }, 1500);
    });
  });

  downloadBtn.addEventListener("click", function () {
    var svgEl = qrContainer.querySelector("svg");
    if (!svgEl) return;
    svgToPngDataUrl(svgEl, function (dataUrl) {
      var a = document.createElement("a");
      var protocol = currentProtocol();
      var streamName = sanitizePath(pathInput.value) || "stream";
      a.href = dataUrl;
      a.download = protocol + "-" + streamName + "-qr.png";
      a.click();
    });
  });

  // Click-to-select on the (readonly) URL field — a fast manual-copy
  // fallback next to the Copy button, useful when the clipboard API is
  // blocked (some in-app/kiosk browsers).
  streamUrlInput.addEventListener("focus", function () {
    streamUrlInput.select();
  });
  streamUrlInput.addEventListener("click", function () {
    streamUrlInput.select();
  });

  portInput.addEventListener("input", function () {
    portTouched = true;
    update();
  });

  form.addEventListener("input", function (e) {
    if (e.target === portInput) return; // handled above
    update();
  });

  restoreState();
  applyProtocolDefaults();
  update();

  // Address/port are usually already right (restored or guessed from the
  // hostname) — jump straight to the field that actually changes per use.
  if (!addressInput.value || !portInput.value) {
    addressInput.focus();
  } else {
    pathInput.focus();
    pathInput.select();
  }
})();
