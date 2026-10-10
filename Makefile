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

.PHONY: web-run
# 本机运行网页版（服务端托管网页并打开浏览器，Ctrl+C 停止）：make web-run
web-run:
	tools/web_run.sh

.PHONY: app-run
# 按当前系统自动选桌面目标；默认服务器为局域网测试端点（tools/deploy.env）
# 跑别的设备：make app-run DEVICE=emulator-5554；连本机服务端：LINKORY_SERVER=http://127.0.0.1:8090 make app-run
app-run:
	tools/app_run.sh $(DEVICE)

.PHONY: deploy deploy-status deploy-logs
# 部署 linkory-server 到局域网测试服务器（tools/deploy.env）
deploy:
	tools/deploy_server.sh
deploy-status:
	tools/deploy_server.sh status
deploy-logs:
	tools/deploy_server.sh logs -n 100

.PHONY: admin-build admin-dev admin-test
admin-build:
	cd linkory-admin && npm ci && npm run build
admin-dev:
	cd linkory-admin && npm run dev
admin-test:
	cd linkory-admin && npm test
