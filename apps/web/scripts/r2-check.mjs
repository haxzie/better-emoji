// Checks that a pair of R2 API keys can list a bucket — what the AWS CLI does in
// CI, minus the CLI. One signed ListObjectsV2 request; exits 0 on 200.
//
//   R2_ACCOUNT_ID=… R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… node r2-check.mjs <bucket>

import { createHash, createHmac } from 'node:crypto';

const bucket = process.argv[2];
const { R2_ACCOUNT_ID: account, R2_ACCESS_KEY_ID: keyId, R2_SECRET_ACCESS_KEY: secret } = process.env;
if (!bucket || !account || !keyId || !secret) {
  console.error('usage: R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY node r2-check.mjs <bucket>');
  process.exit(2);
}

const host = `${account}.r2.cloudflarestorage.com`;
const now = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
const date = now.slice(0, 8);
const sha = (s) => createHash('sha256').update(s).digest('hex');
const hmac = (k, s) => createHmac('sha256', k).update(s).digest();

const query = 'list-type=2&max-keys=1';
const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';
const canonical = [
  'GET',
  `/${bucket}`,
  query,
  `host:${host}\nx-amz-content-sha256:${sha('')}\nx-amz-date:${now}\n`,
  signedHeaders,
  sha(''),
].join('\n');
const scope = `${date}/auto/s3/aws4_request`;
const toSign = ['AWS4-HMAC-SHA256', now, scope, sha(canonical)].join('\n');
const signingKey = ['auto', 's3', 'aws4_request'].reduce((k, s) => hmac(k, s), hmac(`AWS4${secret}`, date));
const signature = createHmac('sha256', signingKey).update(toSign).digest('hex');

const r = await fetch(`https://${host}/${bucket}?${query}`, {
  headers: {
    'x-amz-date': now,
    'x-amz-content-sha256': sha(''),
    authorization: `AWS4-HMAC-SHA256 Credential=${keyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  },
});
if (r.ok) {
  console.log(`✓ R2 keys can read bucket ${bucket}`);
} else {
  console.error(`✗ R2 rejected the keys for bucket ${bucket} (HTTP ${r.status})\n${(await r.text()).slice(0, 300)}`);
  process.exit(1);
}
