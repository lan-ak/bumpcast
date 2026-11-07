// Tooltips for the route charts: point at (or tap) a bar's column to see its numbers.
// The same numbers are in the table under each chart, so nothing depends on this script.
(function () {
  var tip, current;
  function place(band, x, y) {
    if (!tip) {
      tip = document.createElement("div");
      tip.className = "chart-tip";
      tip.setAttribute("role", "status");
      document.body.appendChild(tip);
    }
    if (current && current !== band) current.classList.remove("on");
    current = band;
    band.classList.add("on");
    tip.textContent = band.getAttribute("data-tip");
    tip.hidden = false;
    var w = tip.offsetWidth, h = tip.offsetHeight, pad = 12;
    var left = Math.min(Math.max(pad, x - w / 2), window.innerWidth - w - pad);
    var top = y - h - 14 < pad ? y + 18 : y - h - 14;
    tip.style.left = left + "px";
    tip.style.top = top + "px";
  }
  function hide() {
    if (tip) tip.hidden = true;
    if (current) current.classList.remove("on");
    current = null;
  }
  document.addEventListener("pointermove", function (e) {
    var band = e.target.closest && e.target.closest(".chart .band");
    if (band) place(band, e.clientX, e.clientY);
    else if (current) hide();
  });
  document.addEventListener("pointerdown", function (e) {
    var band = e.target.closest && e.target.closest(".chart .band");
    if (band) place(band, e.clientX, e.clientY);
    else hide();
  });
  window.addEventListener("scroll", hide, { passive: true });
})();
