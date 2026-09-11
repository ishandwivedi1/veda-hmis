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
              ['Total Collection', report.modeSummary.total],
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

      {/* PAYMENT MODE SUMMARY -- straight from Payments, six gross rows,
          no netting or attribution logic. Grand Total is the only
          derived figure (sum of all six, refund rows subtracted). */}
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
            <td style={tdLeft}>Payments against Hospital Billed Items ({report.hospitalBilledItems.count})</td>
            {MODES.map((m) => <td key={m} style={td}>{report.hospitalBilledItems.byMode[m] ? fmt(report.hospitalBilledItems.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 700 }}>{fmt(report.hospitalBilledItems.total)}</td>
          </tr>
          <tr>
            <td style={tdLeft}>Payments Against Opticals ({report.opticalBilledItems.count})</td>
            {MODES.map((m) => <td key={m} style={td}>{report.opticalBilledItems.byMode[m] ? fmt(report.opticalBilledItems.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 700 }}>{fmt(report.opticalBilledItems.total)}</td>
          </tr>
          <tr>
            <td style={tdLeft}>Hospital Advances ({report.hospitalAdvances.count})</td>
            {MODES.map((m) => <td key={m} style={td}>{report.hospitalAdvances.byMode[m] ? fmt(report.hospitalAdvances.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 700 }}>{fmt(report.hospitalAdvances.total)}</td>
          </tr>
          <tr>
            <td style={tdLeft}>Optical Advances ({report.opticalAdvances.count})</td>
            {MODES.map((m) => <td key={m} style={td}>{report.opticalAdvances.byMode[m] ? fmt(report.opticalAdvances.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 700 }}>{fmt(report.opticalAdvances.total)}</td>
          </tr>
          <tr>
            <td style={{ ...tdLeft, color: '#b3261e' }}>Hospital Refunds ({report.hospitalRefunds.count})</td>
            {MODES.map((m) => <td key={m} style={{ ...td, color: '#b3261e' }}>{report.hospitalRefunds.byMode[m] ? fmt(report.hospitalRefunds.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 700, color: '#b3261e' }}>{fmt(report.hospitalRefunds.total)}</td>
          </tr>
          <tr>
            <td style={{ ...tdLeft, color: '#b3261e' }}>Optical Refunds ({report.opticalRefunds.count})</td>
            {MODES.map((m) => <td key={m} style={{ ...td, color: '#b3261e' }}>{report.opticalRefunds.byMode[m] ? fmt(report.opticalRefunds.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 700, color: '#b3261e' }}>{fmt(report.opticalRefunds.total)}</td>
          </tr>
          <tr>
            <td style={{ ...tdLeft, fontWeight: 700 }}>Grand Total (= Total Collection above)</td>
            {MODES.map((m) => <td key={m} style={{ ...td, fontWeight: 700 }}>{report.modeSummary.byMode[m] ? fmt(report.modeSummary.byMode[m]) : '--'}</td>)}
            <td style={{ ...td, fontWeight: 800 }}>{fmt(report.modeSummary.total)}</td>
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
          <CategoryRow label="Optical Shop Sales" cat={report.opticalIncome} bold />
          {report.unclassifiedIncome.total !== 0 && (
            <CategoryRow label="Unclassified -- needs review" cat={report.unclassifiedIncome} bold />
          )}
          <CategoryRow
            label="TOTAL"
            cat={{
              byMode: MODES.reduce((acc, m) => ({ ...acc, [m]: [report.opdIncome, report.pharmacyIncome, report.surgeryIncome, report.unclassifiedIncome, report.opticalIncome].reduce((s, c) => s + (c.byMode[m] || 0), 0) }), {}),
              total: report.opdIncome.total + report.pharmacyIncome.total + report.surgeryIncome.total + report.unclassifiedIncome.total + report.opticalIncome.total,
              advanceAdjusted: report.opdIncome.advanceAdjusted + report.pharmacyIncome.advanceAdjusted + report.surgeryIncome.advanceAdjusted,
              totalWithAdjustment: report.opdIncome.totalWithAdjustment + report.pharmacyIncome.totalWithAdjustment + report.surgeryIncome.totalWithAdjustment + report.unclassifiedIncome.total + report.opticalIncome.total,
            }}
            bold
          />
        </tbody>
      </table>
      <div style={{ fontSize: 10.5, color: '#666', marginBottom: 16 }}>
        Investigation Income equals the "Investigation charges" row above -- already included in OPD Income, not additional.
        "Via Advance" is revenue recognized today by applying an advance collected on an earlier day -- it involves no new cash movement today and is excluded from the Cash/UPI/Card columns and from Total Cash/UPI/Other above.
        Billing-truth, gross (not adjusted for refunds -- see Payment Mode Summary and Day Totals for those). TOTAL = OPD Income + Pharmacy + Surgery Income + Optical Shop Sales (+ Unclassified, if any).
      </div>

      {(report.unclassifiedDepts.length > 0 || report.unclassifiedAdjustedDepts.length > 0) && (
        <div style={{ border: '1px solid #b3261e', padding: 10, marginBottom: 16, fontSize: 11 }}>
          <strong style={{ color: '#b3261e' }}>Flagged for review:</strong>{' '}
          {[...report.unclassifiedDepts, ...report.unclassifiedAdjustedDepts].join(', ')}
        </div>
      )}

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
              {(() => {
                const advanceAdjustmentApplied = report.previousAdvanceAdjustedTotal + report.sameDayAdvanceAdjustedTotal;
                const expectedCollected = report.closing.total_revenue - report.closing.total_outstanding - advanceAdjustmentApplied - report.creditNotesTotal + report.advanceCollectedNet - report.refundsAgainstPreviousInvoices - report.refundsAgainstPreviousAdvances;
                const ties = Math.abs(expectedCollected - report.modeSummary.total) < 0.01;
                return (
                  <>
                    <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                      <tbody>
                        <tr><td style={tdLeft}>Total Billed Revenue (incl. Optical)</td><td style={td}>{fmt(report.closing.total_revenue)}</td></tr>
                        <tr><td style={tdLeft}>Outstanding</td><td style={td}>{fmt(report.closing.total_outstanding)}</td></tr>
                        {advanceAdjustmentApplied > 0.001 && (
                          <tr><td style={{ ...tdLeft, color: '#6d28d9' }}>Advance Adjustment Applied</td><td style={{ ...td, color: '#6d28d9' }}>{fmt(advanceAdjustmentApplied)}</td></tr>
                        )}
                        {report.creditNotesTotal > 0.001 && (
                          <tr><td style={{ ...tdLeft, color: '#b3261e' }}>Credit Notes</td><td style={{ ...td, color: '#b3261e' }}>{fmt(report.creditNotesTotal)}</td></tr>
                        )}
                        <tr><td style={{ ...tdLeft, color: '#6d28d9' }}>Advance Collected</td><td style={{ ...td, color: '#6d28d9' }}>{fmt(report.advanceCollectedNet)}</td></tr>
                        {report.refundsAgainstPreviousInvoices > 0.001 && (
                          <tr><td style={{ ...tdLeft, color: '#b3261e' }}>Refunds against Previous Invoices</td><td style={{ ...td, color: '#b3261e' }}>{fmt(report.refundsAgainstPreviousInvoices)}</td></tr>
                        )}
                        {report.refundsAgainstPreviousAdvances > 0.001 && (
                          <tr><td style={{ ...tdLeft, color: '#b3261e' }}>Refunds against Previous Advances</td><td style={{ ...td, color: '#b3261e' }}>{fmt(report.refundsAgainstPreviousAdvances)}</td></tr>
                        )}
                        <tr><td style={{ ...tdLeft, fontWeight: 700, borderTop: '1px solid #999' }}>Total Collected</td><td style={{ ...td, fontWeight: 700, borderTop: '1px solid #999' }}>{fmt(report.modeSummary.total)}</td></tr>
                        <tr><td style={tdLeft}>Petty Cash Spent</td><td style={td}>{fmt(report.closing.total_petty_cash_expenses)}</td></tr>
                        <tr><td style={tdLeft}>Invoices</td><td style={td}>{report.closing.total_invoices}</td></tr>
                        <tr><td style={tdLeft}>Visits</td><td style={td}>{report.closing.total_visits}</td></tr>
                      </tbody>
                    </table>
                    <div style={{ fontSize: 9.5, color: ties ? '#166534' : '#b3261e', marginTop: 4, fontWeight: 700 }}>
                      {ties ? 'Revenue - Outstanding - Advance Adjustment - Credit Notes + Advance Collected - Refunds (previous invoices/advances) = Total Collected, ties out.' : `Expected ${fmt(expectedCollected)} from the figures above, but Total Collected shows ${fmt(report.modeSummary.total)} -- worth investigating.`}
                    </div>
                  </>
                );
              })()}
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
