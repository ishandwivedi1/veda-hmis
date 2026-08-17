import { renderMedicalFitnessFormHtml } from '@/app/print-templates/actions';
import PrintButton from '../../invoice-print/[invoiceId]/print-button';

export default async function MedicalFitnessFormPrintPage({ params }) {
  const { referralId } = await params;
  const result = await renderMedicalFitnessFormHtml(referralId);

  if (result.error) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>{result.error}</div>;
  }

  return (
    <div>
      <div className="no-print" style={{ textAlign: 'right', padding: '16px 24px 0' }}>
        <PrintButton />
      </div>
      {/* eslint-disable-next-line react/no-danger -- built server-side from
          hospital settings and the referral's own saved form_data, not
          from unescaped end-user input. */}
      <div dangerouslySetInnerHTML={{ __html: result.html }} />
    </div>
  );
}
