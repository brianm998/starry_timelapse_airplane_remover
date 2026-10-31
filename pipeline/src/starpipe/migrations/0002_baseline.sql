CREATE TABLE develop_baseline (
  workflow TEXT NOT NULL,
  job TEXT NOT NULL,
  sha TEXT NOT NULL,
  conclusion TEXT NOT NULL,
  at REAL NOT NULL,
  PRIMARY KEY (workflow, job)
);
CREATE TABLE ci_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ticket INTEGER NOT NULL,
  sha TEXT NOT NULL,
  verdict TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '{}',
  at REAL NOT NULL
);
