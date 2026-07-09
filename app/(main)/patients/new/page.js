import { Suspense } from 'react';
import RegistrationForm from './registration-form';

export default function NewPatientPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <RegistrationForm />
    </Suspense>
  );
}

