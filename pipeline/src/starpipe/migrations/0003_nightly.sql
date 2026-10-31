CREATE TABLE nightly_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started REAL NOT NULL,
  ended REAL,
  ref TEXT NOT NULL,
  sha TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'running',
  summary TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE nightly_results (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run INTEGER NOT NULL REFERENCES nightly_runs(id),
  check_id TEXT NOT NULL,
  status TEXT NOT NULL,
  executed INTEGER NOT NULL DEFAULT 0,
  failed INTEGER NOT NULL DEFAULT 0,
  skipped INTEGER NOT NULL DEFAULT 0,
  seconds REAL NOT NULL DEFAULT 0,
  lock_wait_s REAL NOT NULL DEFAULT 0,
  log TEXT NOT NULL DEFAULT ''
);
CREATE INDEX nightly_results_check ON nightly_results(check_id, run);
