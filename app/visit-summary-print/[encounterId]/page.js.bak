import { createClient } from '@/lib/supabase-server';
import PrintButton from './print-button';

// Same mapping and grouping logic as print-templates/actions.js's
// Handlebars version -- kept in sync deliberately since this page
// renders prescriptions independently (React, not Handlebars).
const FREQUENCY_LABELS = { OD: 'Once a day', BD: 'Twice a day', TDS: 'Three times a day', QID: 'Four times a day', HS: 'At bedtime', SOS: 'As needed' };
function plainFrequency(freq) {
  const label = FREQUENCY_LABELS[freq];
  return label ? `${label} (${freq})` : freq;
}
function groupPrescriptionsForPrint(prescriptions) {
  const seen = new Set();
  const out = [];
  (prescriptions || []).forEach((r) => {
    if (r.taper_group_id) {
      if (seen.has(r.taper_group_id)) return;
      seen.add(r.taper_group_id);
      const steps = prescriptions
        .filter((x) => x.taper_group_id === r.taper_group_id)
        .sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
      out.push({
        id: r.taper_group_id, drug_name: r.drug_name, eye: r.eye, dosage: r.dosage,
        isTaper: true,
        frequency: steps.map((s) => `${plainFrequency(s.frequency)} x${s.duration}`).join(' -> ') + ', then stop',
        duration: '',
      });
    } else {
      out.push({ ...r, frequency: plainFrequency(r.frequency), isTaper: false });
    }
  });
  return out;
}

export default async function VisitSummaryPrintPage({ params }) {
  const { encounterId } = await params;
  const supabase = await createClient();

  const { data: encounter, error } = await supabase
    .from('encounters')
    .select('*, visits(visit_number, patients(first_name, last_name, uhid, age, gender, mobile))')
    .eq('id', encounterId)
    .single();

  if (error || !encounter) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>Visit not found.</div>;
  }

  let doctorName = '--';
  if (encounter.doctor_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', encounter.doctor_id).maybeSingle();
    doctorName = doc?.full_name || '--';
  }

  const [
    { data: diagnoses }, { data: prescriptions }, { data: investigations },
    { data: opticalAdvice }, { data: procedures }, { data: referrals }, { data: counsellingItems }, { data: followup },
  ] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_optical_advice').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_procedures').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_referrals').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_counselling_items').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_followups').select('*').eq('encounter_id', encounterId).maybeSingle(),
  ]);

  const patient = encounter.visits?.patients;
  const visitNumber = encounter.visits?.visit_number;
  const visitDate = new Date(encounter.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'long', year: 'numeric' });

  function Section({ title, children }) {
    return (
      <div style={{ marginBottom: 18 }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: '#1e3a8a', textTransform: 'uppercase', letterSpacing: '.4px', borderBottom: '1px solid #e5e7eb', paddingBottom: 4, marginBottom: 8 }}>
          {title}
        </div>
        {children}
      </div>
    );
  }

  return (
    <div style={{ maxWidth: 750, margin: '0 auto', padding: 30, fontFamily: 'Arial, sans-serif', color: '#111827' }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 20 }}>
        <PrintButton />
      </div>

      <div style={{ textAlign: 'center', borderBottom: '2px solid #1d4ed8', paddingBottom: 16, marginBottom: 20 }}>
        <div style={{ fontSize: 22, fontWeight: 800, color: '#1e3a8a' }}>VEDA EYE HOSPITAL</div>
        <div style={{ fontSize: 12, color: '#6b7280' }}>Haridwar, Uttarakhand</div>
        <div style={{ fontSize: 13, fontWeight: 700, marginTop: 8, color: '#111827' }}>Visit Summary</div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Patient</div>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{patient?.uhid} -- {patient?.age} {patient?.gender}</div>
          {patient?.mobile && <div style={{ fontSize: 12, color: '#4b5563' }}>{patient.mobile}</div>}
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Visit</div>
          <div style={{ fontWeight: 700, fontFamily: 'monospace', fontSize: 14 }}>{visitNumber || '--'}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{visitDate}</div>
          <div style={{ fontSize: 12, color: '#4b5563', marginTop: 2 }}>Dr. {doctorName}</div>
        </div>
      </div>

      {encounter.chief_complaint && (
        <Section title="Chief Complaint">
          <div style={{ fontSize: 13 }}>{encounter.chief_complaint}</div>
        </Section>
      )}

      <Section title="Diagnosis">
        {(diagnoses || []).length === 0 && <div style={{ fontSize: 12, color: '#9ca3af' }}>No diagnosis recorded.</div>}
        {(diagnoses || []).map((d) => (
          <div key={d.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 13 }}>
            <span>
              <strong>{d.name}</strong> -- {d.eye}
            </span>
            <span style={{ color: '#6b7280', fontSize: 11, textTransform: 'capitalize' }}>{d.category}</span>
          </div>
        ))}
      </Section>

      {(prescriptions || []).length > 0 && (
        <Section title="Prescription">
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
            <thead>
              <tr style={{ borderBottom: '1px solid #d1d5db' }}>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Drug</th>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Dosage</th>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Frequency</th>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Duration</th>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Eye</th>
              </tr>
            </thead>
            <tbody>
              {groupPrescriptionsForPrint(prescriptions).map((r) => (
                <tr key={r.id} style={{ borderBottom: '1px solid #f3f4f6' }}>
                  <td style={{ padding: '4px 4px', fontWeight: 600 }}>
                    {r.drug_name}
                    {r.isTaper && <span style={{ fontSize: 9, fontWeight: 700, color: '#7c3aed', textTransform: 'uppercase', marginLeft: 4 }}>(Taper)</span>}
                  </td>
                  <td style={{ padding: '4px 4px' }}>{r.dosage}</td>
                  <td style={{ padding: '4px 4px' }} colSpan={r.isTaper ? 2 : 1}>{r.frequency}</td>
                  {!r.isTaper && <td style={{ padding: '4px 4px' }}>{r.duration}</td>}
                  <td style={{ padding: '4px 4px' }}>{r.eye}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Section>
      )}

      {(investigations || []).length > 0 && (
        <Section title="Investigations Ordered">
          {investigations.map((i) => (
            <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 13 }}>
              <span><strong>{i.name}</strong> -- {i.eye}</span>
              <span style={{ color: '#6b7280', fontSize: 11 }}>{i.priority}</span>
            </div>
          ))}
        </Section>
      )}

      {((opticalAdvice || []).length > 0 || (procedures || []).length > 0 || (referrals || []).length > 0 || (counsellingItems || []).length > 0) && (
        <Section title="Management Plan">
          {(opticalAdvice || []).map((o) => (
            <div key={o.id} style={{ fontSize: 13, padding: '3px 0' }}>-- {o.advice}</div>
          ))}
          {(procedures || []).map((p) => (
            <div key={p.id} style={{ fontSize: 13, padding: '3px 0' }}>-- {p.name} ({p.eye})</div>
          ))}
          {(referrals || []).map((r) => (
            <div key={r.id} style={{ fontSize: 13, padding: '3px 0' }}>-- Referral: {r.destination}{r.reason ? ` (${r.reason})` : ''}</div>
          ))}
          {(counsellingItems || []).map((c) => (
            <div key={c.id} style={{ fontSize: 13, padding: '3px 0' }}>-- Counselling: {c.topic}</div>
          ))}
        </Section>
      )}

      {followup && (
        <Section title="Follow-up">
          <div style={{ fontSize: 13 }}>
            {followup.after_period || (followup.followup_date
              ? new Date(`${followup.followup_date}T00:00:00`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })
              : 'SOS / As Needed')} -- {followup.visit_type} -- {followup.clinic} clinic
          </div>
          {followup.instructions && <div style={{ fontSize: 12, color: '#4b5563', marginTop: 4 }}>{followup.instructions}</div>}
        </Section>
      )}

      {encounter.patient_instructions && (
        <Section title="Patient Instructions">
          <div style={{ fontSize: 13, whiteSpace: 'pre-wrap' }}>{encounter.patient_instructions}</div>
        </Section>
      )}

      <div style={{ marginTop: 50, display: 'flex', justifyContent: 'flex-end' }}>
        <div style={{ textAlign: 'center', borderTop: '1px solid #9ca3af', paddingTop: 6, width: 220 }}>
          <div style={{ fontSize: 12, fontWeight: 600 }}>Dr. {doctorName}</div>
          <div style={{ fontSize: 10, color: '#9ca3af' }}>Signature</div>
        </div>
      </div>

      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 11, color: '#9ca3af' }}>
        This is a computer-generated visit summary.
      </div>
    </div>
  );
}
