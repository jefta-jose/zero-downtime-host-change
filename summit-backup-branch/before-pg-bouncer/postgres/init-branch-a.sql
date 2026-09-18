-- Branch A ("blue"). This DB stands in for one Lakebase branch.
-- The only difference from branch B is the branch_info row, so /db-info can
-- report which branch a backend is currently connected to.

CREATE TABLE IF NOT EXISTS branch_info (
  id          int PRIMARY KEY,
  branch_name text NOT NULL,
  color       text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO branch_info (id, branch_name, color)
VALUES (1, 'BRANCH-A', 'blue')
ON CONFLICT (id) DO NOTHING;

-- A table the backends can write to if you want to generate visible activity.
CREATE TABLE IF NOT EXISTS heartbeat (
  id       bigserial PRIMARY KEY,
  source   text NOT NULL,
  noted_at timestamptz NOT NULL DEFAULT now()
);
