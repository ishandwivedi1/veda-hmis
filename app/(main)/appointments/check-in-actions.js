'use server';

import { redirect } from 'next/navigation';
import { checkInAppointment } from '../visits/actions';

// Check In in ONE request: does the check-in (unchanged -- same
// checkInAppointment as before) and sends back the next screen in the
// same response via redirect(), instead of the button waiting for the
// check-in and then making a 2nd request to load the next page.
// Destinations are the same as before:
//   Surgery / Surgery Evaluation / Investigation Only -> the patient's
//     Surgical Journey case
//   OPD Procedure Only -> the patient's OPD Procedures workspace
//   anything else -> Front Office Dashboard ("Visit created successfully")
export async function checkInAndOpenNext(appointmentId) {
  const result = await checkInAppointment(appointmentId);
  if (result?.error) return { error: result.error };

  if (result.surgicalCaseId) redirect(`/surgical-journey/${result.surgicalCaseId}`);
  if (result.visit?.visit_type === 'OPD Procedure Only' && result.visit?.patient_id) {
    redirect(`/opd-procedures/${result.visit.patient_id}`);
  }
  redirect('/front-office-dashboard?visitCreated=1');
}
