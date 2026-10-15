const status = document.getElementById("status");

function check() {
  status.textContent = "Checking…";
  chrome.runtime.sendMessage({ type: "refresh" }, (reply) => {
    const failed = !!chrome.runtime.lastError; // reading it marks the error as handled
    if (failed || !reply || reply.status === "unreachable" || !reply.status) {
      status.textContent = "Can't reach Osprey. Open Osprey to repair browser integration.";
    } else if (reply.status === "app-not-running") {
      status.textContent = reply.enabled
        ? "Osprey isn't running. It will start automatically when you download a matching file."
        : "Osprey isn't running. Browser integration is turned off in Osprey Settings.";
    } else if (!reply.enabled) {
      status.textContent = "Connected. Browser integration is turned off in Osprey Settings.";
    } else {
      status.textContent = "Connected. Matching downloads go to Osprey. Hold ⌥ Option to let Chrome download instead.";
    }
  });
}

document.getElementById("retry").addEventListener("click", check);
check();
