// A plain target="_blank" link opens a new tab in virtually every modern
// browser regardless of window.open features -- to force an actual
// popup window (separate chrome, fixed size), the link has to be
// replaced with a window.open() call carrying explicit width/height and
// no toolbar/menubar, which is what makes browsers treat it as a popup.
export function openPopup(url, name = 'popup', size = {}) {
  const width = size.width || 900;
  const height = size.height || 800;
  const left = window.screenX + (window.outerWidth - width) / 2;
  const top = window.screenY + (window.outerHeight - height) / 2;
  window.open(
    url,
    name,
    `width=${width},height=${height},left=${left},top=${top},resizable=yes,scrollbars=yes,toolbar=no,menubar=no,location=no,status=no`
  );
}

// Opens a full new browser tab (not a fixed-size popup), while keeping
// window.opener available in that tab. A plain <a target="_blank"> link
// looks identical but does NOT do this: since Chrome 88 / modern
// Firefox, browsers apply rel="noopener" by default to target="_blank"
// links, which nulls out window.opener in the new tab. That silently
// breaks any postMessage-back-to-parent + self-close flow (and
// window.close() is also blocked entirely for tabs that weren't opened
// via script). Calling window.open() directly, with no "noopener" in
// the features string, avoids both problems -- use this instead of a
// target="_blank" link anywhere the opened tab needs to signal back
// and close itself when done.
export function openTab(url, name = '_blank') {
  window.open(url, name);
}

