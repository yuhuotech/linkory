# linkory-core

Rust 核心。目前包含局域网直连传输协议 `LNK1` 的**参考实现**（协议见 `linkory-protocol/PROTOCOL.md`「局域网直连」）：

- `src/lib.rs`：握手（HMAC 双向互证）、HKDF 派生密钥、ChaCha20-Poly1305 分帧、断点续传（接收端上报 `offset`）、SHA-256 校验。
- `src/main.rs`：命令行 `linkory-lan send|recv`，用于与 Dart 客户端做互操作测试和手工排查。

```sh
cargo test                  # 单元测试（回环、错误密钥、断点续传、内容损坏）
cargo build --release       # 产物 target/release/linkory-lan
```

互操作测试在客户端侧：`cd linkory-app && flutter test test/lan_test.dart`（需先 `cargo build --release`），验证 Dart↔Rust 双向兼容。

## 与客户端的关系

客户端目前自带等价的 Dart 实现（`linkory-app/lib/core/lan/lan.dart`），功能完整、已通过上述互操作测试。
Rust 版本在回环上传输 512 MB 约 2 秒（≈240 MB/s），Dart 纯实现受 ChaCha20 软件实现限制（AOT 约 40 MB/s），
后续可通过 FFI 把 `send` / `receive` 接入客户端以获得更高吞吐；接入前需要为各平台配置原生库打包。
