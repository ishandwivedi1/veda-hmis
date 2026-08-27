// Single source of truth for how a patient's name is displayed, so
// salutation shows up consistently everywhere -- screens and printouts
// alike -- instead of being added ad hoc in dozens of places.
export function formatPatientName(patient) {
  if (!patient) return '';
  return [patient.salutation, patient.first_name, patient.last_name].filter(Boolean).join(' ');
}
