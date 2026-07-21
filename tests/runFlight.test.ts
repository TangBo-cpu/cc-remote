import assert from 'node:assert/strict';
import test from 'node:test';
import { createRunFlight } from '../src/runFlight.js';

test('runFlight rejects a second begin while the first flight is held', () => {
  const flight = createRunFlight(() => false);
  assert.equal(flight.tryBegin('prompt'), true);
  assert.equal(flight.isBusy(), true);
  assert.equal(flight.tryBegin('mutate'), false);
  assert.equal(flight.tryBegin('prompt'), false);
  flight.end();
  assert.equal(flight.isBusy(), false);
  assert.equal(flight.tryBegin('mutate'), true);
  flight.end();
});

test('runFlight treats an external process as busy', () => {
  let running = true;
  const flight = createRunFlight(() => running);
  assert.equal(flight.isBusy(), true);
  assert.equal(flight.tryBegin('prompt'), false);
  running = false;
  assert.equal(flight.tryBegin('prompt'), true);
  flight.end();
});

test('runFlight stop request is visible until end', () => {
  const flight = createRunFlight(() => false);
  assert.equal(flight.tryBegin('prompt'), true);
  assert.equal(flight.isStopRequested(), false);
  flight.requestStop();
  assert.equal(flight.isStopRequested(), true);
  flight.end();
  assert.equal(flight.isStopRequested(), false);
});
