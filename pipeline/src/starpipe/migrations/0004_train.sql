CREATE TABLE batches (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  state TEXT NOT NULL,
  base_sha TEXT NOT NULL,
  branch TEXT,
  pr_number INTEGER,
  head_sha TEXT,
  created REAL NOT NULL,
  ci_started REAL,
  ended REAL,
  note TEXT NOT NULL DEFAULT ''
);
CREATE TABLE batch_members (
  batch INTEGER NOT NULL REFERENCES batches(id),
  ticket INTEGER NOT NULL,
  position INTEGER NOT NULL,
  PRIMARY KEY (batch, ticket)
);
