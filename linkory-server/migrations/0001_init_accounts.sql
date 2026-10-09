CREATE TABLE users (
  id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  username      VARCHAR(64)  NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  created_at    DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uk_users_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE devices (
  id           CHAR(36)     NOT NULL PRIMARY KEY,
  user_id      BIGINT UNSIGNED NOT NULL,
  name         VARCHAR(128) NOT NULL,
  device_type  VARCHAR(16)  NOT NULL,
  os_version   VARCHAR(64)  NOT NULL DEFAULT '',
  app_version  VARCHAR(32)  NOT NULL DEFAULT '',
  public_key   VARCHAR(128) NOT NULL,
  status       VARCHAR(16)  NOT NULL DEFAULT 'offline',
  created_at   DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  last_seen_at DATETIME(3)  NULL,
  revoked_at   DATETIME(3)  NULL,
  KEY idx_devices_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE device_sessions (
  id                 CHAR(36)    NOT NULL PRIMARY KEY,
  device_id          CHAR(36)    NOT NULL,
  refresh_token_hash CHAR(64)    NOT NULL,
  expires_at         DATETIME(3) NOT NULL,
  revoked_at         DATETIME(3) NULL,
  created_at         DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uk_sessions_token (refresh_token_hash),
  KEY idx_sessions_device (device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
