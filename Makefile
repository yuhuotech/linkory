.PHONY: server-test server-run up down
server-test:
	cd linkory-server && (set -a; [ -f .env.local ] && . ./.env.local; set +a; go vet ./... && go test ./...)
server-run:
	tools/server_run.sh
up:
	docker compose -f deploy/docker-compose.yml up -d --build
down:
	docker compose -f deploy/docker-compose.yml down

.PHONY: app-test app-macos-dmg
app-test:
	cd linkory-app && flutter analyze && flutter test
app-macos-dmg:
	tools/package_macos.sh

.PHONY: core-test core-build e2e
core-test:
	cd linkory-core && cargo test
core-build:
	cd linkory-core && cargo build --release
# 需要先 make server-run（默认 :8090）；LINKORY_E2E_BIG_MB=1024 可加测大文件
e2e:
	cd linkory-app && LINKORY_E2E_URL=$${LINKORY_E2E_URL:-http://127.0.0.1:8090} flutter test test/e2e_test.dart

.PHONY: app-run
# 按当前系统自动选择桌面目标；想跑别的设备：make app-run DEVICE=emulator-5554
app-run:
	cd linkory-app && flutter run -d $(or $(DEVICE),$(shell case "$$(uname -s)" in Darwin) echo macos;; Linux) echo linux;; *) echo windows;; esac))
