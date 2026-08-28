import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { createClient } from '@/lib/supabase-server';
import CheckInButton from '@/app/(main)/appointments/check-in-button';
import RegisterUnregisteredButton from '@/app/(main)/appointments/register-button';
import { isTodayOpen } from '@/app/(main)/cash-management/actions';
import { VISIT_TYPE_COLOR } from '@/lib/visit-types';

function elapsedMin(iso) {
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

const APPT_STATUS_BADGE = { Booked: 'b-amber', 'Checked-in': 'b-green', Cancelled: 'b-red', 'No-show': 'b-gray' };

export default async function FrontOfficeDashboardPage({ searchParams }) {
  const params = await searchParams;
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { data: todaysRegistrations },
    { data: queueEntries },
    { count: walkInsToday },
    { data: pendingInvoices },
    { data: todaysVisits },
    { data: todaysAppointments },
    { count: surgicalPendingWorkup },
    dayOpen,
  ] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }).gte('created_at', today),
    supabase.from('queue_entries').select('*, visits(patients(first_name, salutation, last_name))').neq('status', 'Done').neq('status', 'Cancelled').gte('issued_at', today).order('issued_at', { ascending: true }),
    supabase.from('visits').select('*', { count: 'exact', head: true }).gte('created_at', today).is('appointment_id', null),
    supabase.from('invoices').select('net, paid').in('status', ['Pending', 'Partial']),
    // Oldest first -- this is front desk's own home page, and the
    // whole point of looking here is "who came first". Newest-first
    // (the old default) put the most recent arrival at the top, which
    // is exactly backwards for that question.
    supabase.from('visits').select('*, patients(id, first_name, salutation, last_name, uhid), profiles!doctor_id(full_name)').gte('created_at', today).order('created_at', { ascending: true }),
    supabase.from('appointments').select('*, patients(first_name, salutation, last_name, uhid, mobile), profiles(full_name)').eq('appointment_date', today).order('appointment_time', { ascending: true }),
    supabase.from('surgical_cases').select('*', { count: 'exact', head: true }).eq('status', 'Pending Workup'),
    isTodayOpen(),
  ]);

  const waitingEntries = (queueEntries || []).filter((e) => e.status === 'Waiting');
  const avgWait = waitingEntries.length
    ? Math.round(waitingEntries.reduce((s, e) => s + elapsedMin(e.issued_at), 0) / waitingEntries.length)
    : 0;

  const outstandingTotal = (pendingInvoices || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);
  const unregisteredCount = (todaysAppointments || []).filter((a) => !a.patients).length;

  // Billing status per visit, batched in one query rather than per-row.
  // A visit can now have multiple invoices (Consultation, Investigation,
  // Pharmacy...) -- aggregate properly rather than keeping whichever one
  // happens to come back last from the query.
  const visitIds = (todaysVisits || []).map((v) => v.id);
  let billingByVisit = {};
  if (visitIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('visit_id, net, paid, status').in('visit_id', visitIds);
    const grouped = {};
    (invoices || []).forEach((inv) => {
      if (!grouped[inv.visit_id]) grouped[inv.visit_id] = [];
      grouped[inv.visit_id].push(inv);
    });
    Object.entries(grouped).forEach(([visitId, invs]) => {
      const active = invs.filter((i) => i.status !== 'Cancelled');
      const outstanding = active.reduce((s, i) => s + Math.max(0, Number(i.net) - Number(i.paid)), 0);
      const allPaid = active.length > 0 && active.every((i) => i.status === 'Paid');
      billingByVisit[visitId] = {
        count: active.length,
        outstanding,
        label: active.length === 0 ? '--' : allPaid ? 'Paid' : `Rs.${outstanding.toLocaleString('en-IN')} due`,
        badge: active.length === 0 ? 'b-gray' : allPaid ? 'b-green' : 'b-red',
      };
    });
  }

  const visitTypeCounts = {};
  (todaysVisits || []).forEach((v) => {
    visitTypeCounts[v.visit_type] = (visitTypeCounts[v.visit_type] || 0) + 1;
  });
  const totalVisitsToday = todaysVisits?.length || 0;

  return (
    <div>
      {!dayOpen && (
        <div className="msg-err" style={{ marginBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span><i className="ti ti-lock"></i> <strong>Today's cash day hasn't been opened.</strong> Payment collection is blocked until it is.</span>
          <Link href="/cash-management" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>Open Day Now</Link>
        </div>
      )}
      {params?.registered && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Registered successfully -- UHID: <strong>{params.registered}</strong>
        </div>
      )}
      {params?.visitCreated && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Visit created successfully.
        </div>
      )}
      {params?.linked && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Patient registered and linked to their appointment.
        </div>
      )}
      {params?.booked && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Appointment booked successfully.
        </div>
      )}

      {/* QUICK ACTIONS */}
      <div className="card" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>
            Quick Actions
          </div>
          <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
            <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
              <i className="ti ti-user-plus"></i> New Registration
            </Link>
            <Link href="/appointments/new" className="btn" style={{ textDecoration: 'none' }}>
              <i className="ti ti-calendar-plus"></i> Book Appointment
            </Link>
            <Link href="/visits/new" className="btn" style={{ textDecoration: 'none' }}>
              <i className="ti ti-stethoscope"></i> New Visit
            </Link>
          </div>
        </div>
      </div>

      {/* STAT CARDS */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Visits</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{totalVisitsToday}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{todaysRegistrations ?? 0} new registrations</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Patients Waiting</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingEntries.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Avg wait: {avgWait} min</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Appointments</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{todaysAppointments?.length ?? 0}</div>
          {unregisteredCount > 0 && <div style={{ fontSize: 11, color: 'var(--red)', marginTop: 2 }}>{unregisteredCount} not registered</div>}
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Billing Pending</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{pendingInvoices?.length ?? 0}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Rs.{outstandingTotal.toLocaleString('en-IN')} outstanding</div>
        </div>
      </div>

      {/* TODAY'S APPOINTMENTS */}
      <div className="card" style={{ marginBottom: 20 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-calendar-event" style={{ color: 'var(--green)' }}></i> Today&apos;s Appointments
        </div>
        <table className="tbl">
          <thead><tr><th>Time</th><th>Patient</th><th>Mobile</th><th>Type</th><th>Doctor</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {(todaysAppointments || []).map((a) => {
              const isRegistered = !!a.patients;
              const name = isRegistered ? `${formatPatientName(a.patients)}` : a.patient_name_temp;
              const mobile = isRegistered ? a.patients.mobile : a.mobile_temp;
              return (
                <tr key={a.id}>
                  <td style={{ fontWeight: 600 }}>{a.appointment_time?.slice(0, 5)}</td>
                  <td>{name}</td>
                  <td>{mobile}</td>
                  <td>{a.visit_type}</td>
                  <td>{a.profiles?.full_name || '--'}</td>
                  <td><span className={`badge ${APPT_STATUS_BADGE[a.status] || 'b-gray'}`}>{a.status}</span></td>
                  <td style={{ position: 'relative' }}>
                    {!isRegistered && <RegisterUnregisteredButton appointmentId={a.id} tempName={a.patient_name_temp} tempMobile={a.mobile_temp} />}
                    {isRegistered && a.status === 'Booked' && <CheckInButton appointmentId={a.id} />}
                    {isRegistered && a.status === 'Checked-in' && <span className="badge b-green">Registered</span>}
                  </td>
                </tr>
              );
            })}
            {(!todaysAppointments || todaysAppointments.length === 0) && (
              <tr><td colSpan={7} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No appointments today.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
        {/* TODAY'S VISITS */}
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
          </div>
          <table className="tbl">
            <thead><tr><th>#</th><th>Visit ID</th><th>Time</th><th>Patient</th><th>Type</th><th>Doctor</th><th>Status</th><th>Billing</th></tr></thead>
            <tbody>
              {(todaysVisits || []).map((v, idx) => {
                const billing = billingByVisit[v.id] || { count: 0, label: '--', badge: 'b-gray' };
                return (
                  <tr key={v.id}>
                    <td style={{ color: 'var(--g400)', fontSize: 12 }}>{idx + 1}</td>
                    <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{v.visit_number || '--'}</td>
                    <td>{new Date(v.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                    <td>
                      <div style={{ fontWeight: 600 }}>{formatPatientName(v.patients)}</div>
                      <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div>
                    </td>
                    <td><span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g100'})`, color: '#fff' }}>{v.visit_type}</span></td>
                    <td>{v.profiles?.full_name || '--'}</td>
                    <td><span className={`badge ${v.status === 'Open' ? 'b-blue' : 'b-gray'}`}>{v.status}</span></td>
                    <td>
                      {billing.badge === 'b-red' && v.patients?.id ? (
                        <Link href={`/payments/collect?patientId=${v.patients.id}`} className="badge b-red" style={{ textDecoration: 'none', cursor: 'pointer' }}>
                          {billing.label}
                        </Link>
                      ) : (
                        <span className={`badge ${billing.badge}`}>{billing.label}</span>
                      )}
                      {billing.count > 1 && <span style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 4 }}>({billing.count} invoices)</span>}
                    </td>
                  </tr>
                );
              })}
              {(!todaysVisits || todaysVisits.length === 0) && (
                <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No visits yet today.</td></tr>
              )}
            </tbody>
          </table>
        </div>

        <div>
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-chart-pie" style={{ color: 'var(--purple)' }}></i> Visits by Type Today
            </div>
            {Object.keys(visitTypeCounts).length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>
            )}
            {Object.entries(visitTypeCounts).map(([type, count]) => (
              <div key={type} style={{ marginBottom: 8 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                  <span>{type}</span><span style={{ fontWeight: 600 }}>{count}</span>
                </div>
                <div style={{ height: 6, background: 'var(--g100)', borderRadius: 3 }}>
                  <div style={{
                    width: `${totalVisitsToday ? (count / totalVisitsToday) * 100 : 0}%`,
                    height: '100%', background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, borderRadius: 3,
                  }}></div>
                </div>
              </div>
            ))}
          </div>

          {/* PATIENTS WAITING NOW */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-list-numbers" style={{ color: 'var(--amber)' }}></i> Patients Waiting Now
            </div>
            {/* Numbered in overall arrival order (#1 = came in first),
                not by token -- tokens reset per department (O-01,
                D-01...) so O-03 and D-02 don't tell you on their own
                who arrived first, even though this list is already
                sorted that way underneath. */}
            {(queueEntries || []).slice(0, 8).map((e, idx) => (
              <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div>
                  <span style={{ color: 'var(--g400)', fontSize: 11, marginRight: 6 }}>#{idx + 1}</span>
                  <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                  {formatPatientName(e.visits?.patients)}
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    {e.department} -- arrived {new Date(e.issued_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} ({elapsedMin(e.issued_at)} min ago)
                  </div>
                </div>
                <span className={`badge ${e.status === 'Calling' || e.status === 'In Consultation' ? 'b-blue' : 'b-amber'}`}>{e.status}</span>
              </div>
            ))}
            {(!queueEntries || queueEntries.length === 0) && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Queue is empty.</div>
            )}
            {(queueEntries || []).length > 8 && (
              <Link href="/queue" style={{ fontSize: 11, color: 'var(--blue)', display: 'block', marginTop: 6 }}>
                + {queueEntries.length - 8} more waiting -- view full queue
              </Link>
            )}
          </div>

          {/* PENDING ACTIONS */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-alert-circle" style={{ color: 'var(--red)' }}></i> Pending Actions
            </div>
            {(pendingInvoices?.length ?? 0) > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                <i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{pendingInvoices.length} invoices -- payment pending</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>Total: Rs.{outstandingTotal.toLocaleString('en-IN')}</div>
                </div>
              </div>
            )}
            {unregisteredCount > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                <i className="ti ti-user-plus" style={{ color: 'var(--amber)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{unregisteredCount} appointments not yet registered</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>See Today&apos;s Appointments above</div>
                </div>
              </div>
            )}
            {(surgicalPendingWorkup ?? 0) > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0' }}>
                <i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{surgicalPendingWorkup} surgical cases pending workup</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    <Link href="/surgical-journey" style={{ color: 'var(--blue)' }}>Go to Surgical Workflow</Link>
                  </div>
                </div>
              </div>
            )}
            {!(pendingInvoices?.length) && !unregisteredCount && !surgicalPendingWorkup && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- all caught up.</div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
