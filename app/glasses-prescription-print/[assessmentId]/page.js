import { renderGlassesPrescriptionHtml } from '@/app/print-templates/actions';
import PrintButton from '../../invoice-print/[invoiceId]/print-button';

export default async function GlassesPrescriptionPrintPage({ params }) {
  const { assessmentId } = await params;
  const result = await renderGlassesPrescriptionHtml(assessmentId);

  if (result.error) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>{result.error}</div>;
  }

  return (
    <div>
      <div className="no-print" style={{ textAlign: 'right', padding: '16px 24px 0' }}>
        <PrintButton />
      </div>
      {/* eslint-disable-next-line react/no-danger -- renderGlassesPrescriptionHtml
          compiles this from the editable print_templates table via
          Handlebars, which HTML-escapes every {{token}} by default; the
          template's own static markup is authored by staff through the
          admin editor, not user input. */}
      <div dangerouslySetInnerHTML={{ __html: result.html }} />
    </div>
  );
}

