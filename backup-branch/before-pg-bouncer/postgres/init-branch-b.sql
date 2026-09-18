-- Branch B ("green"). Identical schema to branch A; only the branch_info row
-- differs, so a backend that switches host reports BRANCH-B instead of BRANCH-A.

CREATE TABLE IF NOT EXISTS branch_info (
  id          int PRIMARY KEY,
  branch_name text NOT NULL,
  color       text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO branch_info (id, branch_name, color)
VALUES (1, 'BRANCH-B', 'green')
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS heartbeat (
  id       bigserial PRIMARY KEY,
  source   text NOT NULL,
  noted_at timestamptz NOT NULL DEFAULT now()
);
