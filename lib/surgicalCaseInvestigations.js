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
export async function addInvestigationToSurgicalCase(supabase, { encounter_id: encounterId, patient_id: patientId, visit_id: visitId }, name, eye, options = {}) {
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
  //
  // options.askBeforeReuse: interactive callers (Surgical Journey's own
  // "Add" button) ask before silently reusing an existing Measured
  // record -- readings can genuinely need a fresh session (second eye
  // years later, notably changed refraction, etc). Automatic callers
  // (Counselling auto-forwarding the doctor's indicative pre-op picks)
  // don't set this -- there's no one at a screen to answer a prompt
  // mid-background-forward, so they keep the old silent-reuse
  // behaviour. options.biometryChoice is the answer coming back from
  // that prompt: 'fresh' always creates a new record; 'existing'
  // explicitly attaches the one on file to THIS case (not a no-op --
  // an investigation_orders row still gets created below either way,
  // so the case's Investigations list shows it and links to the right
  // record regardless of which choice was made).
  if (name.trim().toLowerCase() === 'biometry' && patientId && visitId) {
    if (options.askBeforeReuse && !options.biometryChoice) {
      const { data: existing } = await supabase
        .from('biometry_records')
        .select('id, status, verified_at, updated_at')
        .eq('patient_id', patientId)
        .neq('status', 'Cancelled')
        .order('created_at', { ascending: false })
        .limit(1);
      const onFile = existing && existing.length > 0 ? existing[0] : null;
      if (onFile && onFile.status === 'Measured') {
        return { needsConfirmation: 'biometry', existingBiometryDate: onFile.verified_at || onFile.updated_at };
      }
    }
    const result = await adviseBiometry(patientId, visitId, encounterId, null, options.biometryChoice === 'fresh');
    if (result.error) return result;
  }

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId, name: name.trim(), eye: resolvedEye, priority: 'Routine',
  });
  if (error) return { error: error.message };
  return { success: true };
}
