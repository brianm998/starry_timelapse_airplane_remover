CREATE TABLE gherkin_flakes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  feature TEXT NOT NULL,
  leg TEXT NOT NULL,
  run_id TEXT NOT NULL,
  day TEXT NOT NULL,
  at REAL NOT NULL,
  UNIQUE (feature, leg, run_id)
);
CREATE INDEX gherkin_flakes_feature ON gherkin_flakes(feature);
