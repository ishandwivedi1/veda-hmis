import ReportLetterhead from '@/app/components/ReportLetterhead';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';
import {
  getStockValuationReport, getExpiryReport, getConsumptionReport, getVendorPurchaseSummary,
} from '@/app/(main)/inventory/actions';

const TITLES = {
  valuation: 'Stock Valuation Report',
  expiry: 'Expiry Report',
  consumption: 'Consumption Report',
  vendor: 'Vendor Purchase Summary',
};

function fmtDate(d) {
  return d ? new Date(d).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--';
}
function generatedLine() {
  return `Generated ${new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`;
}

export default async function InventoryReportPrintPage({ params, searchParams }) {
  const { type } = await params;
  const sp = await searchParams;
  const title = TITLES[type];

  if (!title) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>Unknown report type.</div>;
  }

  let subtitle = generatedLine();
  let body;

  if (type === 'valuation') {
    const { rows, totalValue } = await getStockValuationReport();
    body = (
      <>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
          <thead>
            <tr style={{ background: '#e9edf2' }}>
              <th style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>Drug</th>
              <th style={{ border: '1px solid #999', padding: 7 }}>In Stock</th>
              <th style={{ border: '1px solid #999', padding: 7 }}>Avg. Cost</th>
              <th style={{ border: '1px solid #999', padding: 7 }}>Value</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.name}>
                <td style={{ border: '1px solid #999', padding: 7, fontWeight: 600 }}>{r.name}</td>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{r.qty} {r.unit}</td>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>Rs.{r.avgCost.toFixed(2)}</td>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right', fontWeight: 600 }}>Rs.{r.value.toLocaleString('en-IN', { maximumFractionDigits: 0 })}</td>
              </tr>
            ))}
            {rows.length === 0 && <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: '#999' }}>No stock on hand.</td></tr>}
          </tbody>
          <tfoot>
            <tr style={{ fontWeight: 700, background: '#f4f6f8' }}>
              <td colSpan={3} style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>Total Stock Value</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>Rs.{totalValue.toLocaleString('en-IN', { maximumFractionDigits: 0 })}</td>
            </tr>
          </tfoot>
        </table>
      </>
    );
  }

  if (type === 'expiry') {
    const days = sp?.days || '90';
    subtitle = `Batches expiring within ${days} days -- ${generatedLine()}`;
    const rows = await getExpiryReport(days);
    body = (
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr style={{ background: '#e9edf2' }}>
            <th style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>Drug</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Batch</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Expiry Date</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Days Left</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Qty</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((e, i) => (
            <tr key={i}>
              <td style={{ border: '1px solid #999', padding: 7, fontWeight: 600 }}>{e.name}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{e.batchNumber || '--'}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{fmtDate(e.expiryDate)}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center', fontWeight: 600 }}>{e.daysLeft}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{e.qty} {e.unit}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: '#999' }}>Nothing expiring in this window.</td></tr>}
        </tbody>
      </table>
    );
  }

  if (type === 'consumption') {
    const from = sp?.from, to = sp?.to;
    subtitle = `${fmtDate(from)} to ${fmtDate(to)} -- ${generatedLine()}`;
    const rows = await getConsumptionReport(from, to);
    body = (
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr style={{ background: '#e9edf2' }}>
            <th style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>Drug</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Consumed</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((c, i) => (
            <tr key={i}>
              <td style={{ border: '1px solid #999', padding: 7, fontWeight: 600 }}>{c.name}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center', fontWeight: 600 }}>{c.consumed} {c.unit}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={2} style={{ padding: 16, textAlign: 'center', color: '#999' }}>No dispensing recorded in this range.</td></tr>}
        </tbody>
      </table>
    );
  }

  if (type === 'vendor') {
    const from = sp?.from, to = sp?.to;
    subtitle = `${fmtDate(from)} to ${fmtDate(to)} -- ${generatedLine()}`;
    const rows = await getVendorPurchaseSummary(from, to);
    body = (
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr style={{ background: '#e9edf2' }}>
            <th style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>Vendor</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Bills</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Total</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Paid</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Unpaid</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((v, i) => (
            <tr key={i}>
              <td style={{ border: '1px solid #999', padding: 7, fontWeight: 600 }}>{v.name}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{v.bills}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right', fontWeight: 600 }}>Rs.{v.total.toLocaleString('en-IN')}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>Rs.{v.paid.toLocaleString('en-IN')}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right', fontWeight: v.unpaid > 0 ? 600 : 400 }}>Rs.{v.unpaid.toLocaleString('en-IN')}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: '#999' }}>No purchases in this range.</td></tr>}
        </tbody>
      </table>
    );
  }

  return (
    <div style={{ maxWidth: 780, margin: '0 auto', padding: 24 }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 16 }}>
        <PrintButton />
      </div>
      <ReportLetterhead title={title} subtitle={subtitle} />
      {body}
      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        This is a computer-generated report.
      </div>
    </div>
  );
}
