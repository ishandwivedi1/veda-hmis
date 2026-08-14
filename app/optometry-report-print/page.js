import ReportLetterhead from '@/app/components/ReportLetterhead';
import GenericReportPrintBody from '@/app/components/GenericReportPrintBody';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';
import { getOptometryReport } from '@/app/(main)/optometry-reports/actions';

function fmtDate(d) {
  return d ? new Date(d).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--';
}

export default async function OptometryReportPrintPage({ searchParams }) {
  const sp = await searchParams;
  const { reportId, from, to } = sp || {};

  if (!reportId || !from || !to) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>Missing report parameters.</div>;
  }

  const report = await getOptometryReport(reportId, from, to);
  const subtitle = `${fmtDate(from)} to ${fmtDate(to)} -- Generated ${new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`;

  return (
    <div style={{ maxWidth: 780, margin: '0 auto', padding: 24 }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 16 }}>
        <PrintButton />
      </div>
      <ReportLetterhead title={report.title} subtitle={subtitle} />
      <GenericReportPrintBody report={report} />
      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        This is a computer-generated report.
      </div>
    </div>
  );
}
