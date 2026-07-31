(() => {
  const repoName = "taskbars";
  const isGitHubPages = window.location.hostname.endsWith(".github.io");
  const owner = isGitHubPages
    ? window.location.hostname.slice(0, -".github.io".length)
    : "";
  const repositoryURL = owner
    ? `https://github.com/${owner}/${repoName}`
    : "https://github.com/";
  const downloadURL = owner
    ? `${repositoryURL}/releases/latest/download/Taskbar-S.dmg`
    : "../dist/Taskbar-S.dmg";

  document.querySelectorAll("#download-link, #download-link-bottom").forEach((link) => {
    link.href = downloadURL;
  });

  const sourceLink = document.querySelector("#source-link");
  if (sourceLink) sourceLink.href = repositoryURL;

  const year = document.querySelector("#year");
  if (year) year.textContent = new Date().getFullYear();
})();
