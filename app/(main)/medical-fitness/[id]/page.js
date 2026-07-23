import MedicalFitnessWorkspace from './workspace';

export default async function MedicalFitnessWorkspacePage({ params }) {
  const { id } = await params;
  return <MedicalFitnessWorkspace referralId={id} />;
}

