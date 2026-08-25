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
};

export function visitTypeColorVar(type) {
  return VISIT_TYPE_COLOR[type] || '--g400';
}

// Investigation Only and Surgery Evaluation both route to the Doctor
// queue token-wise (department = 'Doctor', same as a normal OPD
// consultation) -- but per hospital feedback, these patients belong
// on the Surgeon Dashboard, not mixed into the OPD Doctor Dashboard's
// queue. In practice these two are the same real-world patient
// (someone here for biometry/investigation is here because of a
// surgical workup), so they're grouped together as one constant
// rather than duplicated everywhere this split matters -- Doctor
// Dashboard filters these OUT, Surgeon Dashboard filters for ONLY
// these, both reading from this single list so they can't drift.
export const SURGICAL_TRACK_VISIT_TYPES = ['Investigation Only', 'Surgery Evaluation'];
