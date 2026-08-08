// Canonical visit-type color mapping, used everywhere a visit type is
// shown as a badge or colored dot -- Doctor Dashboard, Front Office
// Dashboard, Visits, Appointments, Payments' Today's Visits widget.
// Previously this was copy-pasted independently in three different
// files and had drifted: some had 'Procedure' but not 'Surgery', others
// the reverse, so one or the other silently fell back to grey depending
// on which page you were looking at. This is the single source of
// truth now -- update here, and it's correct everywhere.
export const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
  'Surgery': '--indigo',
};

export function visitTypeColorVar(type) {
  return VISIT_TYPE_COLOR[type] || '--g400';
}
