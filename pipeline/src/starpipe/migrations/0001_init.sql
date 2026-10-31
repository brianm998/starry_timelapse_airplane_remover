CREATE TABLE tickets (
  number INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  author TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'queued',
  priority INTEGER NOT NULL DEFAULT 2,
  blocked_by TEXT NOT NULL DEFAULT '[]',
  branch TEXT,
  worktree TEXT,
  plan_json TEXT,
  park_reason TEXT,
  pr_number INTEGER,
  created_at REAL NOT NULL,
  claimed_at REAL,
  updated_at REAL NOT NULL,
  closed_reason TEXT
);
CREATE TABLE stages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ticket INTEGER NOT NULL REFERENCES tickets(number),
  stage TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  model TEXT NOT NULL,
  session_id TEXT,
  started REAL NOT NULL,
  ended REAL,
  lock_wait_s REAL NOT NULL DEFAULT 0,
  outcome TEXT,
  detail TEXT
);
CREATE INDEX stages_ticket ON stages(ticket, stage);
CREATE TABLE checks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ticket INTEGER NOT NULL,
  sha TEXT NOT NULL,
  check_id TEXT NOT NULL,
  result TEXT NOT NULL,
  counts TEXT NOT NULL DEFAULT '{}',
  log TEXT,
  at REAL NOT NULL
);
CREATE TABLE questions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ticket INTEGER NOT NULL,
  stage TEXT NOT NULL,
  text TEXT NOT NULL,
  payload TEXT NOT NULL,
  asked_at REAL NOT NULL,
  comment_id INTEGER,
  answer TEXT,
  answered_at REAL,
  answered_by TEXT
);
CREATE TABLE interventions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ticket INTEGER,
  kind TEXT NOT NULL,
  at REAL NOT NULL,
  stage TEXT
);
CREATE TABLE alerts (
  key TEXT PRIMARY KEY,
  text TEXT NOT NULL,
  opened REAL NOT NULL,
  escalated REAL,
  closed REAL
);
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at REAL NOT NULL,
  ticket INTEGER,
  kind TEXT NOT NULL,
  data TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
