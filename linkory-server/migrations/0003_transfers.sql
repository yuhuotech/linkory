CREATE TABLE transfer_tasks (
  id                 CHAR(36)     NOT NULL PRIMARY KEY,
  user_id            BIGINT UNSIGNED NOT NULL,
  sender_device_id   CHAR(36)     NOT NULL,
  receiver_device_id CHAR(36)     NOT NULL,
  file_name          VARCHAR(255) NOT NULL,
  size               BIGINT UNSIGNED NOT NULL,
  sha256             CHAR(64)     NOT NULL,
  status             VARCHAR(16)  NOT NULL,
  error              VARCHAR(255) NOT NULL DEFAULT '',
  created_at         DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at         DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  KEY idx_tt_sender (sender_device_id, created_at),
  KEY idx_tt_receiver (receiver_device_id, created_at),
  KEY idx_tt_status (status, updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
