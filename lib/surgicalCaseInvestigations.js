// Core "add one investigation to a surgical case" logic, shared by:
//  - Surgical Journey's addInHouseInvestigationForCase (manual add, one
//    at a time, from the case workspace)
//  - Counselling's markForSurgery/updateSurgicalCase (auto-forwarding
//    the doctor's indicative pre-op investigations picked at Advise
//    Surgery -- see consultation-form.js's "Pre Op Requirement" field)
// Kept in one place so both stay in sync -- same dedup rule, same
// Biometry special-case -- rather than drifting apart. Lives in lib/
// rather than either actions.js because counselling/actions.js is
// imported BY surgical-journey/actions.js already; importing the other
// direction too would be a circular import.
// Deliberately NOT a 'use server' file -- it takes a raw supabase
// client as its first argument, which wouldn't survive the
// serialization boundary a real Server Action requires. It's only ever
// called from inside other 'use server' action files, same reasoning
// as lib/prescriptionFormatting.js.
import { adviseBiometry } from '@/app/(main)/consultation/actions';
export async function addInvestigationToSurgicalCase(supabase, { encounter_id: encounterId, patient_id: patientId, visit_id: visitId }, name, eye) {
  if (!name || !name.trim()) return { error: 'Select an investigation.' };
  if (!encounterId) return { error: 'No linked consultation encounter to attach investigations to.' };

  const resolvedEye = eye || 'OU';

  // Don't let the same investigation get ordered twice for this case
  // while an earlier order is still open (Ordered/In Progress).
  const { data: dupe } = await supabase
    .from('investigation_orders')
    .select('id')
    .eq('encounter_id', encounterId)
    .eq('eye', resolvedEye)
    .ilike('name', name.trim())
    .in('status', ['Ordered', 'In Progress'])
    .limit(1);
  if (dupe && dupe.length > 0) {
    return { error: `"${name.trim()}" (${resolvedEye}) is already ordered and still pending for this case.`, alreadyOrdered: true };
  }

  // Biometry is patient-level and fulfilled through its own dedicated
  // module (device readings, IOL recommendations, surgeon approval),
  // not the plain Investigation workspace -- same special-case Doctor
  // Consultation's own addInvestigation already applies. A normal
  // investigation_orders row is still created so it shows up in this
  // same list with a status badge, but the actual biometry_records row
  // is what makes it real.
  if (name.trim().toLowerCase() === 'biometry' && patientId && visitId) {
    const result = await adviseBiometry(patientId, visitId, encounterId, null);
    if (result.error) return result;
  }

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId, name: name.trim(), eye: resolvedEye, priority: 'Routine',
  });
  if (error) return { error: error.message };
  return { success: true };
}
