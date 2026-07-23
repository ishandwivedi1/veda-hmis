// Same type-detection heuristic used by the Queue and Workspace --
// centralized here so History, Comparison, and Reports summarize
// result_data consistently with how it was captured.

export function matchInvestigationType(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('oct')) return 'OCT';
  if (n.includes('visual field') || n.includes(' vf') || n.includes('perimetry')) return 'Visual Field';
  if (n.includes('fundus')) return 'Fundus Photography';
  return 'External Report';
}

export const TYPE_ICON = {
  OCT: 'ti-eye',
  'Visual Field': 'ti-activity',
  'Fundus Photography': 'ti-camera',
  'External Report': 'ti-file-import',
};

// The handful of result_data keys worth showing as a one-line summary
// in list views, per type -- mirrors the field ids the Workspace saves.
const SUMMARY_FIELDS = {
  OCT: [
    { key: 'cmt-re', label: 'CMT' },
    { key: 'rnfl', label: 'RNFL' },
  ],
  'Visual Field': [
    { key: 'md-re', label: 'MD RE' },
    { key: 'md-le', label: 'MD LE' },
    { key: 'vfi', label: 'VFI' },
  ],
  'Fundus Photography': [
    { key: 'img-qual', label: 'Quality' },
  ],
  'External Report': [
    { key: 'doc-type', label: 'Type' },
  ],
};

export function summarizeResultData(type, resultData) {
  const fields = SUMMARY_FIELDS[type] || [];
  const parts = fields
    .map((f) => (resultData?.[f.key] ? `${f.label} ${resultData[f.key]}` : null))
    .filter(Boolean);
  return parts.length > 0 ? parts.join(', ') : '--';
}

// Pulls a leading number out of a free-text field (e.g. "245 um" -> 245,
// "-6.2 dB" -> -6.2) for trend arithmetic in Comparison. Returns null if
// nothing numeric is found rather than guessing.
export function parseNumeric(value) {
  if (value === null || value === undefined) return null;
  const match = String(value).match(/-?\d+(\.\d+)?/);
  return match ? parseFloat(match[0]) : null;
}

