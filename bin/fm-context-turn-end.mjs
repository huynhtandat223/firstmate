// Pi turn-end notification never prevents the existing completion marker.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);
export async function contextTurnEnd(helper, args, turnEnded) {
  try {
    await exec(process.execPath, [helper, ...args]);
  } catch {
    // Context reporting is optional; preserve lifecycle notification on failure.
  } finally {
    await exec('touch', [turnEnded]);
  }
}
