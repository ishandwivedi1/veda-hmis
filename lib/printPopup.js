// Opens a print route (invoice, receipt, investigation report, discharge
// summary, OPD case sheet, visit summary, etc.) as a small centered popup
// window rather than a full new browser tab. Every print entry point
// across the app should route through this instead of a plain
// target="_blank" link, so the experience is consistent everywhere.
export function openPrintPopup(url) {
  const width = 900;
  const height = 760;
  const left = Math.max(0, Math.round((window.screen.width - width) / 2));
  const top = Math.max(0, Math.round((window.screen.height - height) / 2));
  window.open(
    url,
    'veda-print',
    `width=${width},height=${height},top=${top},left=${left},resizable=yes,scrollbars=yes,toolbar=no,menubar=no,location=no,status=no`
  );
}
