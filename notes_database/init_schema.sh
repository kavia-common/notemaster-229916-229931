#!/bin/bash
set -euo pipefail

# Notes App schema initialization (PostgreSQL)
# - MUST use db_connection.txt per container contract
# - Designed to be idempotent: safe to re-run on every startup

if [ ! -f "db_connection.txt" ]; then
  echo "ERROR: db_connection.txt not found. Run startup.sh first (or ensure it created db_connection.txt)."
  exit 1
fi

# db_connection.txt contains: `psql postgresql://user:pass@host:port/dbname`
PSQL_BASE="$(cat db_connection.txt)"

echo "Initializing notes app schema via db_connection.txt..."
echo "Using: ${PSQL_BASE}"

# Ensure extension for UUID generation is available (Postgres 13+ commonly supports pgcrypto)
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# Core tables
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  display_name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);"

${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
CREATE TABLE IF NOT EXISTS notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  is_archived BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);"

${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
CREATE TABLE IF NOT EXISTS tags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_tags_user_name UNIQUE (user_id, name)
);"

${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
CREATE TABLE IF NOT EXISTS note_tags (
  note_id UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  tag_id UUID NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (note_id, tag_id)
);"

# updated_at triggers (simple and generic)
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;"

${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_set_updated_at') THEN
    CREATE TRIGGER trg_users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notes_set_updated_at') THEN
    CREATE TRIGGER trg_notes_set_updated_at
    BEFORE UPDATE ON notes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
  END IF;
END
$$;"

# Indexes (performance for common access patterns)
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_notes_user_updated_at ON notes (user_id, updated_at DESC);"
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_notes_user_created_at ON notes (user_id, created_at DESC);"
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_notes_user_archived ON notes (user_id, is_archived);"
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_tags_user_name ON tags (user_id, name);"
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_note_tags_tag_id ON note_tags (tag_id);"

# Optional search helpers:
# - trigram index helps ILIKE searches on title/content (works well for "search notes")
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_notes_title_trgm ON notes USING gin (title gin_trgm_ops);"
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "CREATE INDEX IF NOT EXISTS idx_notes_content_trgm ON notes USING gin (content gin_trgm_ops);"

# Lightweight seed data:
# - Create a demo user and a couple notes if they don't already exist.
# - Password hash is intentionally a placeholder; backend should manage real hashing.
${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
INSERT INTO users (email, password_hash, display_name)
VALUES ('demo@example.com', 'CHANGE_ME_IN_BACKEND', 'Demo User')
ON CONFLICT (email) DO NOTHING;"

${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
WITH u AS (SELECT id FROM users WHERE email = 'demo@example.com')
INSERT INTO notes (user_id, title, content)
SELECT u.id, 'Welcome to NoteMaster', 'This is your first note. Edit or delete it anytime.'
FROM u
WHERE NOT EXISTS (
  SELECT 1 FROM notes n
  JOIN u ON n.user_id = u.id
  WHERE n.title = 'Welcome to NoteMaster'
);"

${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
WITH u AS (SELECT id FROM users WHERE email = 'demo@example.com')
INSERT INTO tags (user_id, name)
SELECT u.id, 'getting-started'
FROM u
ON CONFLICT (user_id, name) DO NOTHING;"

${PSQL_BASE} -v ON_ERROR_STOP=1 -c "
WITH u AS (SELECT id FROM users WHERE email = 'demo@example.com'),
n AS (
  SELECT id FROM notes
  WHERE user_id = (SELECT id FROM u)
  ORDER BY created_at ASC
  LIMIT 1
),
t AS (
  SELECT id FROM tags
  WHERE user_id = (SELECT id FROM u) AND name = 'getting-started'
)
INSERT INTO note_tags (note_id, tag_id)
SELECT n.id, t.id
FROM n, t
ON CONFLICT DO NOTHING;"

echo "✓ Notes app schema initialization complete."
