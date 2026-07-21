export type FlightOp = 'prompt' | 'mutate';

/**
 * Single-flight gate for daemon mutations.
 * Rejects concurrent prompt/select/register instead of racing across awaits.
 * // ponytail: one holder is enough; upgrade to queue only if callers need FIFO
 */
export function createRunFlight(isProcessRunning: () => boolean) {
  let flight: { op: FlightOp; stopRequested: boolean } | null = null;

  return {
    isBusy(): boolean {
      return flight !== null || isProcessRunning();
    },

    tryBegin(op: FlightOp): boolean {
      if (flight !== null || isProcessRunning()) return false;
      flight = { op, stopRequested: false };
      return true;
    },

    requestStop(): void {
      if (flight) flight.stopRequested = true;
    },

    isStopRequested(): boolean {
      return flight?.stopRequested === true;
    },

    end(): void {
      flight = null;
    },
  };
}

export type RunFlight = ReturnType<typeof createRunFlight>;
