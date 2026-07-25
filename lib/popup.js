// A plain target="_blank" link opens a new tab in virtually every modern
// browser regardless of window.open features -- to force an actual
// popup window (separate chrome, fixed size), the link has to be
// replaced with a window.open() call carrying explicit width/height and
// no toolbar/menubar, which is what makes browsers treat it as a popup.
export function openPopup(url, name = 'popup') {
  const width = 900;
  const height = 800;
  const left = window.screenX + (window.outerWidth - width) / 2;
  const top = window.screenY + (window.outerHeight - height) / 2;
  window.open(
    url,
    name,
    `width=${width},height=${height},left=${left},top=${top},resizable=yes,scrollbars=yes,toolbar=no,menubar=no,location=no,status=no`
  );
}

