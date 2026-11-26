// Local backup of the development database (Docker container vendors-hub-db) into backups/.
// Usage: npm run db:backup   (Docker Desktop must be running)
// Restore: docker exec -i vendors-hub-db pg_restore -U vendors -d vendors_hub --clean < backups/<file>.dump
import { spawn } from 'node:child_process';
import { createWriteStream, mkdirSync, statSync, unlinkSync } from 'node:fs';
import path from 'node:path';

const dir = path.resolve('backups');
mkdirSync(dir, { recursive: true });
const pad = (n) => String(n).padStart(2, '0');
const d = new Date();
const stamp = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
const file = path.join(dir, `vh-${stamp}.dump`);

const out = createWriteStream(file);
const dump = spawn('docker', ['exec', 'vendors-hub-db', 'pg_dump', '-U', 'vendors', '-Fc', 'vendors_hub'], {
  stdio: ['ignore', 'pipe', 'inherit'],
});
dump.stdout.pipe(out);
dump.on('error', (err) => {
  console.error(`Could not run docker: ${err.message}. Is Docker Desktop running?`);
  process.exitCode = 1;
});
dump.on('close', (code) => {
  out.close(() => {
    if (code !== 0) {
      unlinkSync(file);
      console.error('Backup failed (is the vendors-hub-db container running?).');
      process.exitCode = 1;
      return;
    }
    const kb = Math.round(statSync(file).size / 1024);
    console.log(`Backup saved: backups/${path.basename(file)} (${kb} KB)`);
  });
});
