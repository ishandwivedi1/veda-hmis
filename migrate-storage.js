const { createClient } = require('@supabase/supabase-js');

const SOURCE_URL = 'https://zcayavskkbcvkhjdjknu.supabase.co';
const SOURCE_KEY = process.env.SOURCE_SERVICE_KEY;
const TARGET_URL = 'https://flzysyzhaecaqbmdcuao.supabase.co';
const TARGET_KEY = process.env.TARGET_SERVICE_KEY;
const BUCKET = 'clinical-attachments';

const source = createClient(SOURCE_URL, SOURCE_KEY);
const target = createClient(TARGET_URL, TARGET_KEY);

async function listAllFiles(client, bucket, path = '') {
  let files = [];
  const { data, error } = await client.storage.from(bucket).list(path, { limit: 1000 });
  if (error) { console.error('List error at', path, error); return files; }
  for (const item of data) {
    const fullPath = path ? `${path}/${item.name}` : item.name;
    if (item.id === null) {
      // it's a folder, recurse
      const sub = await listAllFiles(client, bucket, fullPath);
      files = files.concat(sub);
    } else {
      files.push(fullPath);
    }
  }
  return files;
}

async function migrate() {
  console.log('Listing files in source bucket...');
  const files = await listAllFiles(source, BUCKET);
  console.log(`Found ${files.length} files to migrate.`);

  let success = 0, failed = 0;
  for (const filePath of files) {
    try {
      const { data: fileData, error: downloadError } = await source.storage.from(BUCKET).download(filePath);
      if (downloadError) throw downloadError;

      const arrayBuffer = await fileData.arrayBuffer();
      const buffer = Buffer.from(arrayBuffer);

      const { error: uploadError } = await target.storage.from(BUCKET).upload(filePath, buffer, {
        contentType: fileData.type || 'application/octet-stream',
        upsert: true,
      });
      if (uploadError) throw uploadError;

      success++;
      console.log(`[${success}/${files.length}] OK: ${filePath}`);
    } catch (err) {
      failed++;
      console.error(`FAILED: ${filePath} —`, err.message || err);
    }
  }
  console.log(`\nDone. Success: ${success}, Failed: ${failed}`);
}

migrate();
