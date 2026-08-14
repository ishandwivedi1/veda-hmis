// Renders the generic tabular report shape (headers/rows/summary/total)
// that getPaymentReport, getInvestigationReport, and getOptometryReport
// all already return -- one shared print body instead of three copies.
export default function GenericReportPrintBody({ report }) {
  return (
    <>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr style={{ background: '#e9edf2' }}>
            {report.headers.map((h) => (
              <th key={h} style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {report.rows.map((row, i) => (
            <tr key={i}>
              {row.cols.map((c, j) => (
                <td key={j} style={{ border: '1px solid #999', padding: 7 }}>{c}</td>
              ))}
            </tr>
          ))}
          {report.rows.length === 0 && (
            <tr><td colSpan={report.headers.length} style={{ padding: 16, textAlign: 'center', color: '#999' }}>No data for this period.</td></tr>
          )}
        </tbody>
      </table>

      {report.summary && (
        <div style={{ display: 'flex', gap: 24, justifyContent: 'flex-end', padding: '10px 0', marginTop: 10 }}>
          {report.summary.map((s) => (
            <div key={s.label} style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 10, color: '#666', textTransform: 'uppercase' }}>{s.label}</div>
              <div style={{ fontSize: s.emphasize ? 15 : 13, fontWeight: 700, color: s.value < 0 ? '#b3261e' : '#1a1a1a' }}>
                {s.value < 0 ? '-' : ''}Rs.{Math.abs(s.value).toFixed(2)}
              </div>
            </div>
          ))}
        </div>
      )}
      {report.total !== null && report.total !== undefined && !report.summary && (
        <div style={{ textAlign: 'right', fontWeight: 700, marginTop: 10, fontSize: 13 }}>
          Total: Rs.{report.total.toFixed(2)}
        </div>
      )}
    </>
  );
}
