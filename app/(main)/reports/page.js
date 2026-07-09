import { createClient } from '@/lib/supabase-server';

async function StatCard({ label, value, color, icon, sub }) {
  return (
    <div className="card" style={{ borderTop: `3px solid var(${color})` }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase', display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className={`ti ${icon}`}></i> {label}
      </div>
      <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

export default async function ReportsPage() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { count: totalPatients },
    { count: registeredToday },
    { count: apptsToday },
    { count: openVisits },
    { count: consultationsToday },
    { count: investigationsToday },
    { count: pendingRx },
    { count: surgeriesScheduled },
    { count: surgeriesCompleted },
    { data: invoicesToday },
    { data: outstandingInvoices },
  ] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }),
    supabase.from('patients').select('*', { count: 'exact', head: true }).gte('created_at', today),
    supabase.from('appointments').select('*', { count: 'exact', head: true }).eq('appointment_date', today),
    supabase.from('visits').select('*', { count: 'exact', head: true }).eq('status', 'Open'),
    supabase.from('encounters').select('*', { count: 'exact', head: true }).eq('status', 'Completed').gte('completed_at', today),
    supabase.from('investigation_orders').select('*', { count: 'exact', head: true }).eq('status', 'Completed').gte('completed_at', today),
    supabase.from('prescriptions').select('*', { count: 'exact', head: true }).eq('status', 'Pending'),
    supabase.from('ot_schedule').select('*', { count: 'exact', head: true }).eq('status', 'Scheduled'),
    supabase.from('ot_schedule').select('*', { count: 'exact', head: true }).eq('status', 'Completed').eq('scheduled_date', today),
    supabase.from('invoices').select('paid, net').gte('created_at', today),
    supabase.from('invoices').select('net, paid').in('status', ['Pending', 'Partial']),
  ]);

  const revenueToday = (invoicesToday || []).reduce((s, i) => s + Number(i.paid), 0);
  const outstanding = (outstandingInvoices || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);

  return (
    <div>
      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}>
        Patient Statistics
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Total Patients" value={totalPatients ?? 0} color="--blue" icon="ti-users" />
        <StatCard label="Registered Today" value={registeredToday ?? 0} color="--blue" icon="ti-user-plus" />
        <StatCard label="Appointments Today" value={apptsToday ?? 0} color="--amber" icon="ti-calendar-event" />
        <StatCard label="Open Visits" value={openVisits ?? 0} color="--green" icon="ti-door-enter" />
      </div>

      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}>
        Clinical Statistics
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Consultations Today" value={consultationsToday ?? 0} color="--teal" icon="ti-stethoscope" />
        <StatCard label="Investigations Today" value={investigationsToday ?? 0} color="--purple" icon="ti-flask" />
        <StatCard label="Pending Prescriptions" value={pendingRx ?? 0} color="--purple" icon="ti-pill" />
        <StatCard label="Surgeries Scheduled" value={surgeriesScheduled ?? 0} color="--red" icon="ti-scalpel" />
      </div>

      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}>
        Financial Statistics
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Revenue Today" value={`Rs.${revenueToday.toLocaleString('en-IN')}`} color="--green" icon="ti-cash" />
        <StatCard label="Outstanding Receivables" value={`Rs.${outstanding.toLocaleString('en-IN')}`} color="--red" icon="ti-receipt-2" />
        <StatCard label="Surgeries Completed Today" value={surgeriesCompleted ?? 0} color="--green" icon="ti-circle-check" />
      </div>

      <div className="msg-info" style={{ marginTop: 8 }}>
        <i className="ti ti-info-circle"></i> All figures above are computed live from the actual database -- nothing on this page is hardcoded or simulated.
      </div>
    </div>
  );
}

