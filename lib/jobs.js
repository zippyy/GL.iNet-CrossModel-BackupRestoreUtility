import crypto from 'node:crypto';
import { HttpError } from './util.js';

// Job state machine for long-running SSH operations.
//
// A browser request must not own the lifecycle of a backup/validate/restore
// operation. Jobs persist under /data/jobs and expose:
//   state: queued | running | succeeded | failed | rolled-back | rollback-failed
// plus correlation ID, timestamps, progress notes, a sanitized transcript,
// and the canonical engine result markers.

export const JOB_STATES = ['queued', 'running', 'succeeded', 'failed', 'rolled-back', 'rollback-failed'];

export class JobManager {
  constructor({ store, logger }) {
    this.store = store;
    this.logger = logger;
    this.running = new Map(); // id -> { job, controller }
  }

  newId() { return crypto.randomUUID(); }

  async create({ type, routerId, routerLabel, profileId, correlationId, payload = {} }) {
    const job = {
      id: this.newId(),
      type, // backup | validate | restore | activate | packages | facts
      state: 'queued',
      correlationId: correlationId || this.newId(),
      routerId: routerId || null,
      routerLabel: routerLabel || null,
      profileId: profileId || null,
      payload: this.#sanitizePayload(payload),
      createdAt: new Date().toISOString(),
      startedAt: null,
      finishedAt: null,
      progress: [],
      markers: {},
      result: null,
      error: null,
      rollbackProfileId: null // set when a restore created a rollback snapshot (retention guard)
    };
    await this.store.saveJob(job);
    return job;
  }

  #sanitizePayload(payload) {
    const { password, privateKey, agent, ...safe } = payload || {};
    return safe;
  }

  async get(id) {
    const job = await this.store.job(id);
    return job;
  }

  async list() { return this.store.listJobs(); }

  async #update(id, patch) {
    const current = await this.store.job(id);
    const next = { ...current, ...patch };
    await this.store.saveJob(next);
    return next;
  }

  async start(id) {
    await this.#update(id, { state: 'running', startedAt: new Date().toISOString() });
  }

  async note(id, message, fields = {}) {
    const current = await this.store.job(id);
    const entry = { at: new Date().toISOString(), message, ...fields };
    await this.store.saveJob({ ...current, progress: [...current.progress, entry].slice(-500) });
  }

  async succeed(id, { result, markers = {}, progress = [] } = {}) {
    const current = await this.store.job(id);
    await this.store.saveJob({
      ...current,
      state: 'succeeded',
      finishedAt: new Date().toISOString(),
      result: result ?? current.result,
      markers,
      progress: [...current.progress, ...progress].slice(-1000)
    });
  }

  async fail(id, { error, markers = {}, rollbackState = null } = {}) {
    const current = await this.store.job(id);
    const state = rollbackState || 'failed'; // rollbackState: 'rolled-back' | 'rollback-failed'
    await this.store.saveJob({
      ...current,
      state,
      finishedAt: new Date().toISOString(),
      error: String(error?.message || error || 'Operation failed.').slice(0, 2000),
      markers,
      result: rollbackState ? { rollback: rollbackState } : current.result
    });
  }

  // Run a task as a job. Handles start/succeed/fail transitions and keeps the
  // in-memory controller registry for potential cancellation.
  async run(id, task) {
    const controller = { cancelled: false, cancel: () => { controller.cancelled = true; } };
    this.running.set(id, { job: await this.get(id), controller });
    await this.start(id);
    try {
      const outcome = await task({ jobId: id, note: (m, f) => this.note(id, m, f), isCancelled: () => controller.cancelled });
      await this.succeed(id, { result: outcome?.result, markers: outcome?.markers, progress: outcome?.progress });
      return { id, state: 'succeeded', ...outcome };
    } catch (error) {
      const rollbackState = error?.rollbackState || null;
      await this.fail(id, { error, markers: error?.markers, rollbackState });
      const state = rollbackState || 'failed';
      const result = { id, state };
      if (rollbackState) result.rollback = rollbackState;
      result.error = String(error?.message || error).slice(0, 2000);
      return result;
    } finally {
      this.running.delete(id);
    }
  }
}

export function jobError(message, { rollbackState, markers, code } = {}) {
  const error = new Error(message);
  error.rollbackState = rollbackState || null;
  error.markers = markers || {};
  error.code = code || null;
  return error;
}

export function assertJobState(job, allowed) {
  if (!job || !allowed.includes(job.state)) {
    throw new HttpError(409, `Job is not in a ${allowed.join('/')} state.`);
  }
}
