import ReportLetterhead from '@/app/components/ReportLetterhead';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';
import { getDailyReport } from '@/app/(main)/cash-management/actions';

const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

function fmt(n) {
  return `Rs.${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtDate(d) {
  return d ? new Date(d).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--';
}

const th = { border: '1px solid #999', padding: '6px 8px', textAlign: 'right', fontSize: 11, background: '#e9edf2' };
const thLeft = { ...th, textAlign: 'left' };
const td = { border: '1px solid #999', padding: '6px 8px', textAlign: 'right', fontSize: 12 };
const tdLeft = { ...td, textAlign: 'left' };

// One row for a category, in the same 5-mode column order every time,
// plus a Via Advance column and a Total column -- consistent columns
// regardless of which modes an individual category actually used, so
// the printed table reads as a clean grid rather than ragged per-row
// columns. italic+indent marks a row as a constituent of the bold
// parent above it (OPD Income's three components), so the roll-up
// structure reads clearly on a printed page without needing color.
function CategoryRow({ label, cat, bold, italic }) {
  const style = {
    ...(bold ? { fontWeight: 700 } : {}),
    ...(italic ? { fontStyle: 'italic', fontWeight: 400, color: '#444' } : {}),
  };
  const labelStyle = italic ? { ...tdLeft, ...style, paddingLeft: 36 } : { ...tdLeft, ...style };
  return (
    <tr>
      <td style={labelStyle}>{label}</td>
      {MODES.map((m) => <td key={m} style={{ ...td, ...style }}>{cat.byMode[m] ? fmt(cat.byMode[m]) : '--'}</td>)}
      <td style={{ ...td, ...style, color: italic ? style.color : (cat.advanceAdjusted > 0.001 ? '#6d28d9' : undefined) }}>{cat.advanceAdjusted > 0.001 ? fmt(cat.advanceAdjusted) : '--'}</td>
      <td style={{ ...td, ...style, fontWeight: bold ? 700 : (italic ? 400 : 700) }}>{fmt(cat.totalWithAdjustment ?? cat.total)}</td>
    </tr>
  );
}

export default async function CashDailyReportPrintPage({ searchParams }) {
  const sp = await searchParams;
  const date = sp?.date;

  if (!date) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>Missing report date.</div>;
  }

  const report = await getDailyReport(date);

  if (!report?.closing) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>No closed day on record for {fmtDate(date)}.</div>;
  }

  const totalOther = MODES.filter((m) => m !== 'Cash' && m !== 'UPI').reduce((s, m) => s + (report.modeSummary.byMode[m] || 0), 0);

  return (
    <div style={{ maxWidth: 900, margin: '0 auto', padding: 24, fontFamily: 'Arial, Helvetica, sans-serif' }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 16 }}>
        <PrintButton />
      </div>

      <ReportLetterhead
        title="DAILY CASH CLOSING REPORT"
        subtitle={`Date: ${fmtDate(report.closing.closing_date)} -- Closed by ${report.closing.profiles?.full_name || '--'} at ${new Date(report.closing.closed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata' })}`}
      />

      {/* KPI SUMMARY */}
      <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 18 }}>
        <tbody>
          <tr>
            {[
              ['Total Revenue (billed)', report.closing.total_revenue],
              ['Total Cash', report.modeSummary.byMode['Cash'] || 0],
              ['Total UPI', report.modeSummary.byMode['UPI'] || 0],
              ['Total Other', totalOther],
            ].map(([label, val]) => (
              <td key={label} style={{ border: '1px solid #999', padding: '10px 12px', width: '25%', textAlign: 'center' }}>
                <div style={{ fontSize: 10, color: '#666', textTransform: 'uppercase' }}>{label}</div>
                <div style={{ fontSize: 15, fontWeight: 800, marginTop: 3 }}>{fmt(val)}</div>
              </td>
            ))}
          </tr>
        </tbody>
      </table>

      {/* INCOME BY CATEGORY */}
      <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 6 }}>Income by Category</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 6 }}>
        <thead>
          <tr>
            <th style={thLeft}>Category</th>
            {MODES.map((m) => <th key={m} style={th}>{m}</th>)}
            <th style={th}>Via Advance</th>
            <th style={th}>Total</th>
          </tr>
        </thead>
        <tbody>
          <CategoryRow label="OPD Income" cat={report.opdIncome} bold />
          <CategoryRow label="OPD Consultation charges" cat={report.opdIncome.consultation} italic />
          <CategoryRow label="Procedure charges" cat={report.opdIncome.procedure} italic />
          <CategoryRow label="Investigation charges" cat={report.opdIncome.investigation} italic />
          <CategoryRow label="Pharmacy" cat={report.pharmacyIncome} bold />
          <CategoryRow label="Surgery Income" cat={report.surgeryIncome} bold />
          {report.unclassifiedIncome.total !== 0 && (
            <CategoryRow label="Unclassified -- needs review" cat={report.unclassifiedIncome} bold />
          )}
        </tbody>
      </table>
      <div style={{ fontSize: 10.5, color: '#666', marginBottom: 16 }}>
        Investigation Income equals the "Investigation charges" row above -- already included in OPD Income, not additional.
        "Via Advance" is revenue recognized today by applying an advance collected on an earlier day -- it involves no new cash movement today and is excluded from the Cash/UPI/Card columns and from Total Cash/UPI/Other above.
      </div>

      {(report.unclassifiedDepts.length > 0 || report.unclassifiedAdjustedDepts.length > 0) && (
        <div style={{ border: '1px solid #b3261e', padding: 10, marginBottom: 16, fontSize: 11 }}>
          <strong style={{ color: '#b3261e' }}>Flagged for review:</strong>{' '}
          {[...report.unclassifiedDepts, ...report.unclassifiedAdjustedDepts].join(', ')}
        </div>
      )}

      {/* BILLED ITEMS / ADVANCES / REFUNDS */}
      <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 6 }}>Payment Mode Summary</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 18 }}>
        <thead>
          <tr>
            <th style={thLeft}>Type</th>
            {MODES.map((m) => <th key={m} style={th}>{m}</th>)}
            <th style={th}>Total</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td style={tdLeft}>Billed Items ({report.billedItems.count})</td>
            {MODES.map((m) => <td key={m} style={td}>{report.billedItems.byMode[m] ? fmt(report.billedItems.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 700 }}>{fmt(report.billedItems.total)}</td>
          </tr>
          <tr>
            <td style={tdLeft}>Advances ({report.advances.count})</td>
            {MODES.map((m) => <td key={m} style={td}>{report.advances.byMode[m] ? fmt(report.advances.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 700 }}>{fmt(report.advances.total)}</td>
          </tr>
          {report.refunds.total !== 0 && (
            <tr>
              <td style={{ ...tdLeft, color: '#b3261e' }}>Refunds paid out</td>
              {MODES.map((m) => <td key={m} style={{ ...td, color: '#b3261e' }}>{report.refunds.byMode[m] ? fmt(report.refunds.byMode[m]) : '--'}</td>)}
              <td style={{ ...td, fontWeight: 700, color: '#b3261e' }}>{fmt(report.refunds.total)}</td>
            </tr>
          )}
          <tr>
            <td style={{ ...tdLeft, fontWeight: 700 }}>Grand Total (actual cash movement)</td>
            {MODES.map((m) => <td key={m} style={{ ...td, fontWeight: 700 }}>{report.modeSummary.byMode[m] ? fmt(report.modeSummary.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 800 }}>{fmt(report.modeSummary.total)}</td>
          </tr>
        </tbody>
      </table>

      {/* RECONCILIATION + DAY TOTALS */}
      <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 18 }}>
        <tbody>
          <tr>
            <td style={{ verticalAlign: 'top', width: '50%', paddingRight: 12 }}>
              <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 6 }}>Reconciliation Summary</div>
              <table style={{ width: '100%', borderCollapse: 'collapse' }}>
                <thead><tr><th style={thLeft}>Mode</th><th style={th}>Actual</th><th style={th}>Variance</th></tr></thead>
                <tbody>
                  {report.reconciliation.map((r) => (
                    <tr key={r.id}>
                      <td style={tdLeft}>{r.mode}</td>
                      <td style={td}>{fmt(r.actual)}</td>
                      <td style={{ ...td, color: Math.abs(r.variance) > 0.01 ? '#b3261e' : undefined }}>
                        {Math.abs(r.variance) > 0.01 ? `${r.variance > 0 ? '+' : ''}${fmt(r.variance)}` : '--'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </td>
            <td style={{ verticalAlign: 'top', width: '50%', paddingLeft: 12 }}>
              <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 6 }}>Day Totals</div>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                <tbody>
                  <tr><td style={tdLeft}>Total Revenue (billed)</td><td style={td}>{fmt(report.closing.total_revenue)}</td></tr>
                  <tr><td style={tdLeft}>Total Collected</td><td style={td}>{fmt(report.closing.total_collected)}</td></tr>
                  <tr><td style={tdLeft}>Outstanding</td><td style={td}>{fmt(report.closing.total_outstanding)}</td></tr>
                  <tr><td style={tdLeft}>Petty Cash Spent</td><td style={td}>{fmt(report.closing.total_petty_cash_expenses)}</td></tr>
                  <tr><td style={tdLeft}>Invoices</td><td style={td}>{report.closing.total_invoices}</td></tr>
                  <tr><td style={tdLeft}>Visits</td><td style={td}>{report.closing.total_visits}</td></tr>
                </tbody>
              </table>
            </td>
          </tr>
        </tbody>
      </table>

      {/* PETTY CASH EXPENSES */}
      {report.expenses.length > 0 && (
        <>
          <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 6 }}>Petty Cash Expenses</div>
          <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 18 }}>
            <thead>
              <tr><th style={thLeft}>Category</th><th style={thLeft}>Remarks</th><th style={thLeft}>Entered By</th><th style={th}>Amount</th></tr>
            </thead>
            <tbody>
              {report.expenses.map((exp) => (
                <tr key={exp.id}>
                  <td style={tdLeft}>{exp.master_expense_categories?.name}</td>
                  <td style={tdLeft}>{exp.paid_to || '--'}</td>
                  <td style={tdLeft}>{exp.profiles?.full_name || 'Staff'}</td>
                  <td style={{ ...td, fontWeight: 700 }}>{fmt(exp.amount)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}

      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        This is a computer-generated report. Generated {new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}.
      </div>
    </div>
  );
}
