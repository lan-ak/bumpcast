// Matches the sky to the visitor's local time, like the app does for a flight's departure time.
// Dark mode always uses the night sky (handled in CSS).
(function () {
  var h = new Date().getHours();
  var sky = h >= 5 && h < 9 ? "dawn" : h >= 9 && h < 17 ? "day" : h >= 17 && h < 20 ? "dusk" : "night";
  document.documentElement.setAttribute("data-sky", sky);
  document.addEventListener("DOMContentLoaded", function () {
    var dark = window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches;
    var note = document.querySelector("[data-skynote]");
    if (note) note.textContent = "Sky set to your local time · " + (dark ? "night" : sky);
  });
})();
