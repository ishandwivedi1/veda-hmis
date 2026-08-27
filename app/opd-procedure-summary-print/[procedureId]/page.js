import { renderOpdProcedureSummaryHtml } from '@/app/print-templates/actions';
import PrintButton from './print-button';

export default async function OpdProcedureSummaryPrintPage({ params }) {
  const { procedureId } = await params;
  const result = await renderOpdProcedureSummaryHtml(procedureId);

  if (result.error) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>{result.error}</div>;
  }

  return (
    <div>
      <div className="no-print" style={{ textAlign: 'right', padding: '16px 24px 0' }}>
        <PrintButton />
      </div>
      {/* eslint-disable-next-line react/no-danger -- renderOpdProcedureSummaryHtml
          compiles this from the editable print_templates table via
          Handlebars, which HTML-escapes every {{token}} by default; the
          template's own static markup is authored by staff through the
          admin editor, not user input. */}
      <div dangerouslySetInnerHTML={{ __html: result.html }} />
    </div>
  );
}
