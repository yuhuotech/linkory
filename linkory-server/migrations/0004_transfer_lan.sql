ALTER TABLE transfer_tasks
  ADD COLUMN lan_secret CHAR(64)   NOT NULL DEFAULT '' AFTER sha256,
  ADD COLUMN mode       VARCHAR(8) NOT NULL DEFAULT 'relay' AFTER status
