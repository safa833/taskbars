(() => {
  const repositoryURL = "https://github.com/safa833/taskbars";
  const downloadURL = "https://github.com/safa833/taskbars/releases/download/v0.2.0/Taskbar-S-0.2.0.dmg";

  document.querySelectorAll("#download-link, #download-link-bottom").forEach((link) => {
    link.href = downloadURL;
  });

  const sourceLink = document.querySelector("#source-link");
  if (sourceLink) sourceLink.href = repositoryURL;

  const year = document.querySelector("#year");
  if (year) year.textContent = new Date().getFullYear();
})();
