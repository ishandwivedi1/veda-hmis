import AssessmentViewer from './assessment-viewer';

export default async function OptometryHistoryDetailPage({ params }) {
  const { assessmentId } = await params;
  return <AssessmentViewer assessmentId={assessmentId} />;
}
