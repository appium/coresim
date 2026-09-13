import {wrapNativeError} from '../errors.js';

/** Shared by NativeSimctl and every `src/commands/*.ts` mixin — maps a raw error surfaced by the addon to a typed one. */
export async function runCatchingAsync<T>(fn: () => Promise<T>): Promise<T> {
  try {
    return await fn();
  } catch (err) {
    wrapNativeError(err);
  }
}
