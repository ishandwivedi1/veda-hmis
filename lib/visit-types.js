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
  'Surgery Evaluation': '--cyan',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
  'Surgery': '--indigo',
  'In House Camp': '--lime',
};

export function visitTypeColorVar(type) {
  return VISIT_TYPE_COLOR[type] || '--g400';
}

// Investigation Only and Surgery Evaluation are both only valid for a
// patient already marked for surgery on a previous OPD visit -- a
// "wants time to decide" patient coming back to book, or a pure
// biometry/investigation follow-up. Neither issues a queue token
// (enforced server-side in create_walk_in_visit/check_in_appointment,
// which reject the visit if no open surgical case exists) -- they
// attach straight to the patient's existing case, same as a Surgery
// visit skips the queue entirely. Surfaced in Surgical Journey via an
// "Arrived Today" indicator (getSurgicalTrackArrivalsToday) rather
// than any dashboard queue. Grouped as one constant since they're
// the same real-world patient in practice, so both sides of that
// query stay in sync.
export const SURGICAL_TRACK_VISIT_TYPES = ['Investigation Only', 'Surgery Evaluation'];
