// The route picker: choose two airports and go to that route's page, in either direction.
// For a pair without a page, it says so and offers the app, which forecasts any covered flight.
// Without this script the picker stays hidden; the links and table on the page reach every route.
(function () {
  function setUp(form) {
    var data = JSON.parse(form.querySelector("[data-routes]").textContent);
    var from = form.elements.from, to = form.elements.to;
    var miss = form.querySelector(".picker-miss");
    var airports = [];
    for (var i = 0; i < to.options.length; i++) {
      if (to.options[i].value) airports.push([to.options[i].value, to.options[i].textContent]);
    }
    function page(a, b) { return data.pairs[a + "-" + b] || data.pairs[b + "-" + a]; }

    // Once "From" is chosen, "To" lists the airports with a route page first.
    function fillTo() {
      var keep = to.value, a = from.value;
      to.innerHTML = "";
      to.add(new Option("Choose an airport", ""));
      if (!a) {
        airports.forEach(function (ap) { to.add(new Option(ap[1], ap[0])); });
      } else {
        var linked = document.createElement("optgroup"), other = document.createElement("optgroup");
        linked.label = "Route pages";
        other.label = "Other airports";
        airports.forEach(function (ap) {
          if (ap[0] !== a) (page(a, ap[0]) ? linked : other).appendChild(new Option(ap[1], ap[0]));
        });
        if (linked.children.length) to.appendChild(linked);
        if (other.children.length) to.appendChild(other);
      }
      to.value = keep && keep !== a ? keep : "";
    }

    from.addEventListener("change", function () { fillTo(); miss.hidden = true; });
    to.addEventListener("change", function () { miss.hidden = true; });
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      if (!from.value || !to.value) { (from.value ? to : from).focus(); return; }
      var href = page(from.value, to.value);
      if (href) { window.location.href = href; return; }
      miss.querySelector("[data-pair]").textContent = from.value + " to " + to.value;
      miss.hidden = false;
    });
    form.hidden = false;
  }
  var forms = document.querySelectorAll("[data-picker]");
  for (var i = 0; i < forms.length; i++) setUp(forms[i]);
})();
