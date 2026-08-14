import { createClient } from '@/lib/supabase-server';
import ReportLetterhead from '@/app/components/ReportLetterhead';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';

function StatRow({ label, value }) {
  return (
    <tr>
      <td style={{ border: '1px solid #999', padding: 7, color: '#444' }}>{label}</td>
      <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right', fontWeight: 700 }}>{value}</td>
    </tr>
  );
}

export default async function ReportsSnapshotPrintPage() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { count: totalPatients }, { count: registeredToday }, { count: apptsToday }, { count: openVisits },
    { count: consultationsToday }, { count: investigationsToday }, { count: pendingRx },
    { count: surgeriesScheduled }, { count: surgeriesCompleted },
    { data: invoicesToday }, { data: outstandingInvoices },
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
  const subtitle = `Hospital Snapshot -- ${new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`;

  return (
    <div style={{ maxWidth: 780, margin: '0 auto', padding: 24 }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 16 }}>
        <PrintButton />
      </div>
      <ReportLetterhead title="Hospital Snapshot Report" subtitle={subtitle} />

      <div style={{ fontSize: 12, fontWeight: 700, color: '#444', textTransform: 'uppercase', margin: '16px 0 8px' }}>Patient Statistics</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12, marginBottom: 16 }}>
        <tbody>
          <StatRow label="Total Patients" value={totalPatients ?? 0} />
          <StatRow label="Registered Today" value={registeredToday ?? 0} />
          <StatRow label="Appointments Today" value={apptsToday ?? 0} />
          <StatRow label="Open Visits" value={openVisits ?? 0} />
        </tbody>
      </table>

      <div style={{ fontSize: 12, fontWeight: 700, color: '#444', textTransform: 'uppercase', margin: '16px 0 8px' }}>Clinical Statistics</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12, marginBottom: 16 }}>
        <tbody>
          <StatRow label="Consultations Today" value={consultationsToday ?? 0} />
          <StatRow label="Investigations Today" value={investigationsToday ?? 0} />
          <StatRow label="Pending Prescriptions" value={pendingRx ?? 0} />
          <StatRow label="Surgeries Scheduled" value={surgeriesScheduled ?? 0} />
        </tbody>
      </table>

      <div style={{ fontSize: 12, fontWeight: 700, color: '#444', textTransform: 'uppercase', margin: '16px 0 8px' }}>Financial Statistics</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12, marginBottom: 16 }}>
        <tbody>
          <StatRow label="Revenue Today" value={`Rs.${revenueToday.toLocaleString('en-IN')}`} />
          <StatRow label="Outstanding Receivables" value={`Rs.${outstanding.toLocaleString('en-IN')}`} />
          <StatRow label="Surgeries Completed Today" value={surgeriesCompleted ?? 0} />
        </tbody>
      </table>

      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        All figures computed live from the database at the time this report was generated.
      </div>
    </div>
  );
}
