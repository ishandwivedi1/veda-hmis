// Single source of truth for how a patient's name is displayed, so
// salutation shows up consistently everywhere -- screens and printouts
// alike -- instead of being added ad hoc in dozens of places.
export function formatPatientName(patient) {
  if (!patient) return '';
  return [patient.salutation, patient.first_name, patient.last_name].filter(Boolean).join(' ');
}

// Age alongside a name in a queue/call-out list -- lets front desk,
// optometry, and doctors tell apart two same-name patients (or just
// confirm they're calling the right one) at a glance. Returns '' when
// age isn't on file so callers can drop it cleanly rather than
// showing a stray "(--)" next to every name.
export function formatPatientAge(patient) {
  if (patient?.age === null || patient?.age === undefined || patient?.age === '') return '';
  return `${patient.age}y`;
}
