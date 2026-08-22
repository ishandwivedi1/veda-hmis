// Computes how much Pharmacy should actually dispense for a
// prescription (or a whole tapering schedule) instead of leaving it to
// a per-row manual guess. Two drug forms behave completely differently:
//
//   - Countable forms (Tablet, Capsule -- master_drug_types.is_countable)
//     have a discrete per-administration count ("1 tablet", "2 capsules",
//     "1/2 tablet") that can be multiplied out: dose x times-per-day x
//     days = total units to dispense. A 4-step taper (QID -> TDS -> BD ->
//     OD, 1 week each) sums to one number, not four separate purchases.
//
//   - Non-countable forms (Eye Drop, Eye Ointment, Gel, Syrup, Injection)
//     are dispensed as a single bottle/tube/vial regardless of how the
//     dose or frequency is written -- "2 drops QID" is still one bottle,
//     not eight. Quantity is always 1 here, no matter how many taper
//     steps there are.
//
// This is deliberately conservative: if any factor can't be read with
// confidence (an SOS/as-needed step, an Ongoing/open-ended step, or
// dosage text that doesn't parse to a number), the whole computation
// bails out to null rather than silently producing a wrong number --
// Pharmacy falls back to manual entry in that case, same as today.

const FRACTION_GLYPHS = { '½': 0.5, '¼': 0.25, '¾': 0.75, '⅓': 1 / 3, '⅔': 2 / 3 };

// Doses per day for each shorthand the app uses. SOS ("as needed") has
// no fixed count -- intentionally absent, not zero.
const FREQUENCY_PER_DAY = { OD: 1, BD: 2, TDS: 3, QID: 4, HS: 1 };

// Standard pharmacy convention: 1 week = 7 days, 1 month = 30 days.
// "Ongoing" is intentionally absent -- it's open-ended, not computable.
function parseDurationDays(durationText) {
  if (!durationText) return null;
  const t = durationText.trim().toLowerCase();
  const m = t.match(/^(\d+)\s*(day|days|week|weeks|month|months)$/);
  if (!m) return null;
  const n = Number(m[1]);
  if (m[2].startsWith('day')) return n;
  if (m[2].startsWith('week')) return n * 7;
  return n * 30; // month
}

// Extracts the leading per-administration count from dosage text, e.g.
// "1 tablet" -> 1, "2 tablets" -> 2, "½ tablet" -> 0.5, "1/2 tablet" ->
// 0.5. Returns null (not a guess) for qualitative dosage text like
// "Apply thin layer" or "As directed" -- those never reach this
// function anyway since they're on non-countable types, but it stays
// safe if that ever changes.
function parseDoseCount(dosageText) {
  if (!dosageText) return null;
  const t = dosageText.trim();
  const glyph = t.match(/^([½¼¾⅓⅔])/);
  if (glyph) return FRACTION_GLYPHS[glyph[1]];
  const frac = t.match(/^(\d+)\s*\/\s*(\d+)/);
  if (frac) return Number(frac[1]) / Number(frac[2]);
  const num = t.match(/^(\d+(\.\d+)?)/);
  if (num) return Number(num[1]);
  return null;
}

// steps: [{ dosage, frequency, duration }, ...] -- a single prescription
// is just a one-element array of the same shape.
export function computeDispenseQty(steps, isCountable) {
  if (!isCountable) {
    return { qty: 1, computed: false, needsManualEntry: false, reason: null };
  }
  let total = 0;
  for (const s of steps || []) {
    const doseCount = parseDoseCount(s.dosage);
    const perDay = FREQUENCY_PER_DAY[s.frequency];
    const days = parseDurationDays(s.duration);
    if (doseCount == null || perDay == null || days == null) {
      return {
        qty: null, computed: false, needsManualEntry: true,
        reason: 'Includes an as-needed (SOS) or open-ended (Ongoing) step, or a dosage that could not be read automatically -- enter quantity manually.',
      };
    }
    total += doseCount * perDay * days;
  }
  // Round up -- a pack can't dispense a fractional tablet even if the
  // math lands on e.g. 10.5.
  return { qty: Math.ceil(total), computed: true, needsManualEntry: false, reason: null };
}
