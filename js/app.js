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

  function currentProtocol() {
    var checked = form.querySelector('input[name="protocol"]:checked');
    return checked ? checked.value : "rtsp";
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

    var qr = qrcode(0, "M");
    qr.addData(text);
    qr.make();
    qrContainer.innerHTML = qr.createSvgTag(6, 8);
    downloadBtn.hidden = false;
  }

  function update() {
    applyProtocolDefaults();
    var url = buildStreamUrl();
    streamUrlInput.value = url;
    renderQr(url);
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

  portInput.addEventListener("input", function () {
    portTouched = true;
    update();
  });

  form.addEventListener("input", function (e) {
    if (e.target === portInput) return; // handled above
    update();
  });

  applyProtocolDefaults();
  update();
})();
