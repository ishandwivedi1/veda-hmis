// Shared logger for visit_journey_events -- an append-only record of
// the moments in a patient's day that a single-row "current status"
// column can't hold onto (repeat trips to the doctor, per-destination
// send-out times, etc). Called from server actions across queue,
// investigation, biometry, payments, and pharmacy, each passing their
// own already-open supabase client so this doesn't open a second
// connection per call.
//
// Never throws -- a failed log write should not block the actual
// clinical/billing action it's attached to. Best-effort only.
export async function logJourneyEvent(supabase, visitId, eventType, meta = {}) {
  if (!visitId) return;
  try {
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('visit_journey_events').insert({
      visit_id: visitId,
      event_type: eventType,
      meta,
      created_by: userData?.user?.id || null,
    });
  } catch (err) {
    console.error('logJourneyEvent failed:', eventType, visitId, err?.message);
  }
}
