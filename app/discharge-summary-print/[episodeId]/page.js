import { createClient } from '@/lib/supabase-server';
import PrintButton from './print-button';

export default async function DischargeSummaryPrintPage({ params }) {
  const { episodeId } = await params;
  const supabase = await createClient();

  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid, age, gender, mobile), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();

  if (error || !episode) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>Episode not found.</div>;
  }
  if (!episode.discharge_date) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>This patient hasn&apos;t been discharged yet.</div>;
  }

  const sc = episode.surgical_cases;
  const patient = sc.patients;

  const [{ data: intraop }, { data: biometry }, { data: meds }, { data: followups }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    supabase.from('biometry_records').select('final_iol_power, final_iol_category, surgical_eye').eq('visit_id', episode.visit_id).eq('status', 'Approved'),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
  ]);

  function formatDate(d) {
    if (!d) return '--';
    return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'long', year: 'numeric' });
  }

  function Section({ title, children }) {
    return (
      <div style={{ marginBottom: 18 }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: '#0f766e', textTransform: 'uppercase', letterSpacing: '.4px', borderBottom: '1px solid #e5e7eb', paddingBottom: 4, marginBottom: 8 }}>
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

      <div style={{ textAlign: 'center', borderBottom: '2px solid #0f766e', paddingBottom: 16, marginBottom: 20 }}>
        <div style={{ fontSize: 22, fontWeight: 800, color: '#0f766e' }}>VEDA EYE HOSPITAL</div>
        <div style={{ fontSize: 12, color: '#6b7280' }}>Haridwar, Uttarakhand</div>
        <div style={{ fontSize: 13, fontWeight: 700, marginTop: 8, color: '#111827' }}>Discharge Summary</div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Patient</div>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{patient?.uhid} -- {patient?.age} {patient?.gender}</div>
          {patient?.mobile && <div style={{ fontSize: 12, color: '#4b5563' }}>{patient.mobile}</div>}
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Surgeon</div>
          <div style={{ fontWeight: 700, fontSize: 14 }}>Dr. {sc.profiles?.full_name || '--'}</div>
          <div style={{ fontSize: 12, color: '#4b5563', marginTop: 2 }}>Discharged: {formatDate(episode.discharge_date)}</div>
        </div>
      </div>

      <Section title="Episode Dates">
        <div style={{ display: 'flex', gap: 30, fontSize: 13 }}>
          <div><span style={{ color: '#6b7280' }}>Admission: </span>{formatDate(episode.admission_date)}</div>
          <div><span style={{ color: '#6b7280' }}>Surgery: </span>{formatDate(episode.surgery_date)}</div>
          <div><span style={{ color: '#6b7280' }}>Discharge: </span>{formatDate(episode.discharge_date)}</div>
        </div>
      </Section>

      <Section title="Procedure Summary">
        <div style={{ fontSize: 13, padding: '3px 0' }}>Procedure: <strong>{sc.procedure_name}</strong> ({sc.eye})</div>
        {(biometry || []).map((p) => (
          <div key={p.surgical_eye} style={{ fontSize: 13, padding: '3px 0' }}>
            IOL ({p.surgical_eye}): <strong>{intraop?.implant_power || p.final_iol_power} D -- {p.final_iol_category}</strong>
            {intraop?.implant_manufacturer && ` -- ${intraop.implant_manufacturer} ${intraop.implant_model || ''}`}
          </div>
        ))}
      </Section>

      <Section title="Medications">
        {(meds || []).length === 0 && <div style={{ fontSize: 12, color: '#9ca3af' }}>None prescribed.</div>}
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
          <tbody>
            {(meds || []).map((m) => (
              <tr key={m.id}>
                <td style={{ padding: '4px 8px 4px 0', fontWeight: 600 }}>{m.name}</td>
                <td style={{ padding: '4px 0', color: '#4b5563' }}>{m.sig}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>

      {episode.discharge_notes && (
        <Section title="Discharge Notes (Doctor)">
          <div style={{ fontSize: 13, whiteSpace: 'pre-wrap' }}>{episode.discharge_notes}</div>
        </Section>
      )}

      <Section title="Discharge Instructions">
        <div style={{ fontSize: 13, whiteSpace: 'pre-wrap' }}>{episode.discharge_instructions || 'As advised by the surgeon.'}</div>
      </Section>

      <Section title="Follow-up Schedule">
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
          <thead>
            <tr style={{ background: '#f0fdfa' }}>
              <th style={{ textAlign: 'left', padding: '5px 8px', color: '#0f766e' }}>Visit</th>
              <th style={{ textAlign: 'left', padding: '5px 8px', color: '#0f766e' }}>Date</th>
              <th style={{ textAlign: 'left', padding: '5px 8px', color: '#0f766e' }}>Status</th>
            </tr>
          </thead>
          <tbody>
            {(followups || []).map((f) => (
              <tr key={f.id}>
                <td style={{ padding: '4px 8px' }}>{f.visit_label}</td>
                <td style={{ padding: '4px 8px', color: '#4b5563' }}>{formatDate(f.scheduled_date)}</td>
                <td style={{ padding: '4px 8px', color: '#4b5563' }}>{f.status}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>

      <div style={{ marginTop: 50, display: 'flex', justifyContent: 'flex-end' }}>
        <div style={{ textAlign: 'center', borderTop: '1px solid #9ca3af', paddingTop: 6, width: 220 }}>
          <div style={{ fontSize: 12, fontWeight: 600 }}>Dr. {sc.profiles?.full_name || '--'}</div>
          <div style={{ fontSize: 10, color: '#9ca3af' }}>Signature</div>
        </div>
      </div>

      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 11, color: '#9ca3af' }}>
        This is a computer-generated discharge summary -- Veda Eye Hospital.
      </div>
    </div>
  );
}

