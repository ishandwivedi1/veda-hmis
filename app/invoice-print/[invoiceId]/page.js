import Link from 'next/link';
import { renderInvoiceHtml } from '@/app/print-templates/actions';
import PrintButton from './print-button';

export default async function InvoicePrintPage({ params, searchParams }) {
  const { invoiceId } = await params;
  const sp = await searchParams;
  const includeBreakup = sp?.breakup === '1';
  const result = await renderInvoiceHtml(invoiceId, includeBreakup);

  if (result.error) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>{result.error}</div>;
  }

  return (
    <div>
      <div className="no-print" style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 10, padding: '16px 24px 0' }}>
        {result.breakupAvailable && (
          includeBreakup ? (
            <Link href={`/invoice-print/${invoiceId}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>
              <i className="ti ti-list-details"></i> Showing package breakup -- switch to plain copy
            </Link>
          ) : (
            <Link href={`/invoice-print/${invoiceId}?breakup=1`} className="btn btn-sm" style={{ textDecoration: 'none' }}>
              <i className="ti ti-list-details"></i> Include package breakup (insurance copy)
            </Link>
          )
        )}
        <PrintButton />
      </div>
      {/* eslint-disable-next-line react/no-danger -- renderInvoiceHtml
          compiles this from the editable print_templates table via
          Handlebars, which HTML-escapes every {{token}} by default; the
          template's own static markup is authored by staff through the
          admin editor, not user input. */}
      <div dangerouslySetInnerHTML={{ __html: result.html }} />
    </div>
  );
}
