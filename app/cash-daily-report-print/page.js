import ReportLetterhead from '@/app/components/ReportLetterhead';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';
import { getDailyReport } from '@/app/(main)/cash-management/actions';

// Table 1's display columns -- Card/Cheque/Bank Transfer dropped per
// explicit request; this hospital's payments are always Cash or UPI.
// totalOther above stays dynamic (not tied to this list).
const MODES = ['Cash', 'UPI'];

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

// One row for a category -- Table 2 is billing-truth for account-book
// entry: full billed value plus exactly how it was settled, split by
// Cash/UPI (see getBilledIncomeByCategory). blankExtras leaves Billed/
// Settled via Advance/Credit Notes/Outstanding empty rather than
// showing Rs.0.00 -- used for the advance-only rows and Grand Total,
// where those columns genuinely don't apply. highlight marks the
// Total Billed row.
function CategoryRow({ label, row, bold, flag, blankExtras, highlight }) {
  const style = { fontWeight: bold ? 700 : 400, color: flag ? '#b3261e' : undefined };
  const rowStyle = highlight ? { background: '#eff6ff' } : undefined;
  return (
    <tr style={rowStyle}>
      <td style={{ ...tdLeft, ...style, fontWeight: highlight ? 800 : style.fontWeight, wordBreak: 'break-word' }}>{label}</td>
      <td style={{ ...td, ...style, color: '#1d4ed8', fontWeight: highlight ? 800 : style.fontWeight }}>{blankExtras ? '' : fmt(row.billed)}</td>
      <td style={{ ...td, ...style, fontWeight: highlight ? 800 : style.fontWeight }}>{fmt(row.netCash)}</td>
      <td style={{ ...td, ...style, fontWeight: highlight ? 800 : style.fontWeight }}>{fmt(row.netUPI)}</td>
      <td style={{ ...td, ...style, color: row.advanceSettled ? '#6d28d9' : style.color, fontWeight: highlight ? 800 : style.fontWeight }}>{blankExtras ? '' : fmt(row.advanceSettled)}</td>
      <td style={{ ...td, ...style, color: row.creditNoteSettled ? '#b3261e' : style.color, fontWeight: highlight ? 800 : style.fontWeight }}>{blankExtras ? '' : fmt(row.creditNoteSettled)}</td>
      <td style={{ ...td, ...style, color: row.outstanding ? '#92400e' : style.color, fontWeight: highlight ? 800 : style.fontWeight }}>{blankExtras ? '' : fmt(row.outstanding)}</td>
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

  // Dynamic, not tied to the MODES list below (Table 1's display
  // columns) -- so this KPI never silently hides real money collected
  // via a mode Table 1 no longer shows a column for.
  const totalOther = Object.entries(report.modeSummary.byMode).filter(([m]) => m !== 'Cash' && m !== 'UPI').reduce((s, [, amt]) => s + amt, 0);

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
            <td style={tdLeft}>Payments Against Billed Optical Items ({report.opticalBilledItems.count})</td>
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

      {/* TABLE 2: BILLED INCOME BY CATEGORY -- pure billing-truth,
          straight from invoice_line_items/optical_sales for what was
          actually invoiced today, regardless of collection status. */}
      <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 6 }}>Billed Income by Category</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 6, tableLayout: 'fixed' }}>
        <colgroup>
          <col style={{ width: '24%' }} />
          <col style={{ width: '12.67%' }} />
          <col style={{ width: '12.67%' }} />
          <col style={{ width: '12.67%' }} />
          <col style={{ width: '12.67%' }} />
          <col style={{ width: '12.67%' }} />
          <col style={{ width: '12.67%' }} />
        </colgroup>
        <thead>
          <tr>
            <th style={thLeft}>Category</th>
            <th style={th}>Billed</th>
            <th style={th}>Net Cash Collected</th>
            <th style={th}>Net UPI Collected</th>
            <th style={th}>Settled via Advance</th>
            <th style={th}>Credit Notes</th>
            <th style={th}>Outstanding</th>
          </tr>
        </thead>
        <tbody>
          {(() => {
            const c = report.billedCategories;
            const rows = [
              { label: 'OPD Consultation charges', row: c['OPD Consultation charges'] },
              { label: 'Procedure charges', row: c['Procedure charges'] },
              { label: 'Investigation charges', row: c['Investigation charges'] },
              { label: 'Pharmacy', row: c.Pharmacy },
              { label: 'Surgery Income', row: c['Surgery Income'] },
              { label: 'Optical Shop Sales', row: c['Optical Shop Sales'] },
            ];
            if (c.Unclassified.billed !== 0) rows.push({ label: 'Unclassified -- needs review', row: c.Unclassified, flag: true });
            const total = rows.reduce((acc, r) => ({
              billed: acc.billed + r.row.billed, netCash: acc.netCash + r.row.netCash, netUPI: acc.netUPI + r.row.netUPI,
              advanceSettled: acc.advanceSettled + r.row.advanceSettled, creditNoteSettled: acc.creditNoteSettled + r.row.creditNoteSettled, outstanding: acc.outstanding + r.row.outstanding,
            }), { billed: 0, netCash: 0, netUPI: 0, advanceSettled: 0, creditNoteSettled: 0, outstanding: 0 });
            return (
              <>
                {rows.map((r) => <CategoryRow key={r.label} label={r.label} row={r.row} flag={r.flag} />)}
                <CategoryRow label="Total Billed" row={total} highlight />
                {(() => {
                  // Advances have no category/dept of their own, so
                  // they only ever populate Net Cash/Net UPI. Grand
                  // Total's Net Cash/Net UPI reproduces Payment Mode
                  // Summary's Grand Total exactly (see getDailyReport).
                  const advanceRows = [
                    { label: 'Net Hospital Advance Collected', row: report.netHospitalAdvanceCollected },
                    { label: 'Net Optical Advance Collected', row: report.netOpticalAdvanceCollected },
                    { label: 'Previous Hospital Advance Refund', row: report.previousHospitalAdvanceRefund },
                    { label: 'Previous Optical Advance Returned', row: report.previousOpticalAdvanceReturned },
                  ];
                  const asFullRow = (r) => ({ billed: 0, netCash: r.netCash, netUPI: r.netUPI, advanceSettled: 0, creditNoteSettled: 0, outstanding: 0 });
                  const grandTotal = {
                    billed: total.billed,
                    netCash: total.netCash + advanceRows.reduce((s, r) => s + r.row.netCash, 0),
                    netUPI: total.netUPI + advanceRows.reduce((s, r) => s + r.row.netUPI, 0),
                    advanceSettled: total.advanceSettled, creditNoteSettled: total.creditNoteSettled, outstanding: total.outstanding,
                  };
                  return (
                    <>
                      {advanceRows.map((r) => <CategoryRow key={r.label} label={r.label} row={asFullRow(r.row)} blankExtras />)}
                      <CategoryRow label="Grand Total" row={grandTotal} bold blankExtras />
                    </>
                  );
                })()}
              </>
            );
          })()}
        </tbody>
      </table>
      <div style={{ fontSize: 10.5, color: '#666', marginBottom: 16 }}>
        Each row: Billed = Net Cash + Net UPI + Settled via Advance + Credit Notes + Outstanding. Net Cash/UPI are net of today's refunds against today's own invoices only. Total Billed = Total Billed Revenue in Day Totals below. Advances have no category of their own, so they only populate Net Cash/Net UPI -- Grand Total's Net Cash/Net UPI equals Payment Mode Summary's Grand Total above.
      </div>

      {report.unclassifiedDepts.length > 0 && (
        <div style={{ border: '1px solid #b3261e', padding: 10, marginBottom: 16, fontSize: 11 }}>
          <strong style={{ color: '#b3261e' }}>Flagged for review:</strong>{' '}
          {report.unclassifiedDepts.join(', ')}
        </div>
      )}

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

      {/* CASH COUNTER -- same source as the live Step 2 tab, so a
          closed day's figures here match exactly what was confirmed
          that day. Cash Collected is gross (Table 1's Cash column,
          before expenses). */}
      <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 6 }}>Cash Counter</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 18 }}>
        <tbody>
          <tr><td style={tdLeft}>Opening Cash</td><td style={{ ...td, fontWeight: 700 }}>{fmt(report.cashCounter.openingCash)}</td></tr>
          <tr><td style={tdLeft}>Cash Collected</td><td style={{ ...td, fontWeight: 700, color: '#166534' }}>{fmt(report.cashCounter.cashCollected)}</td></tr>
          <tr><td style={tdLeft}>Cash Expenses</td><td style={{ ...td, fontWeight: 700, color: '#b3261e' }}>{fmt(report.cashCounter.cashExpenses)}</td></tr>
          <tr><td style={tdLeft}>Cash Retained</td><td style={{ ...td, fontWeight: 700, color: '#6d28d9' }}>{report.cashCounter.closingCash != null ? fmt(report.cashCounter.closingCash) : 'Pending'}</td></tr>
          <tr style={{ background: '#eff6ff' }}>
            <td style={{ ...tdLeft, fontWeight: 800 }}>Cash Handed Over</td>
            <td style={{ ...td, fontWeight: 800, color: '#1d4ed8' }}>{report.cashCounter.amountHandedOver != null ? fmt(report.cashCounter.amountHandedOver) : 'Pending'}</td>
          </tr>
        </tbody>
      </table>

      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        This is a computer-generated report. Generated {new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}.
      </div>
    </div>
  );
}
