CREATE TABLE conversations (
  id         CHAR(36)    NOT NULL PRIMARY KEY,
  user_id    BIGINT UNSIGNED NOT NULL,
  device_lo  CHAR(36)    NOT NULL,
  device_hi  CHAR(36)    NOT NULL,
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uk_conv_pair (device_lo, device_hi),
  KEY idx_conv_user (user_id, updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE messages (
  id                 CHAR(36)    NOT NULL PRIMARY KEY,
  conversation_id    CHAR(36)    NOT NULL,
  client_msg_id      CHAR(36)    NOT NULL,
  sender_device_id   CHAR(36)    NOT NULL,
  receiver_device_id CHAR(36)    NOT NULL,
  msg_type           VARCHAR(16) NOT NULL,
  content            TEXT        NOT NULL,
  created_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  delivered_at       DATETIME(3) NULL,
  UNIQUE KEY uk_msg_idem (sender_device_id, client_msg_id),
  KEY idx_msg_conv (conversation_id, created_at),
  KEY idx_msg_pending (receiver_device_id, delivered_at, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
