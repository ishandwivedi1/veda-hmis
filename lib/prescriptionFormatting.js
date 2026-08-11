// Doctors enter frequency as the medical shorthand (fast to pick from a
// dropdown) but that shorthand means nothing to a patient reading their
// printed prescription at home -- translated to plain language here.
// This is deliberately a plain module, not a 'use server' one: both
// values are pure synchronous helpers, and Next.js requires every
// export from a 'use server' file to be an async function (Server
// Actions must be callable from the client), which these aren't and
// shouldn't need to be.
const FREQUENCY_LABELS = {
  OD: 'Once a day',
  BD: 'Twice a day',
  TDS: 'Three times a day',
  QID: 'Four times a day',
  HS: 'At bedtime',
  SOS: 'As needed',
};

export function plainFrequency(freq) {
  const label = FREQUENCY_LABELS[freq];
  return label ? `${label} (${freq})` : freq;
}

// Groups prescription rows sharing a taper_group_id into one entry with
// a combined frequency string (e.g. "QID x1 week -> TDS x1 week -> BD
// x1 week -> OD x1 week, then stop") so a tapering schedule prints as
// one coherent instruction instead of N separate-looking prescriptions.
export function groupPrescriptionsForPrint(prescriptions) {
  const seen = new Set();
  const out = [];
  prescriptions.forEach((r) => {
    if (r.taper_group_id) {
      if (seen.has(r.taper_group_id)) return;
      seen.add(r.taper_group_id);
      const steps = prescriptions
        .filter((x) => x.taper_group_id === r.taper_group_id)
        .sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
      out.push({
        drug: r.drug, eye: r.eye, dosage: r.dosage,
        isTaper: true,
        frequency: steps.map((s) => `${plainFrequency(s.frequency)} x${s.duration}`).join(' -> ') + ', then stop',
        duration: '',
      });
    } else {
      out.push({ drug: r.drug, eye: r.eye, dosage: r.dosage, frequency: plainFrequency(r.frequency), duration: r.duration, isTaper: false });
    }
  });
  return out;
}
