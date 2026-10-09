class Device {
  Device({
    required this.id,
    required this.name,
    required this.type,
    required this.osVersion,
    required this.appVersion,
    required this.status,
    required this.current,
    this.lastSeenAt,
  });
  final String id, name, type, osVersion, appVersion, status;
  final bool current;
  final DateTime? lastSeenAt;

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'],
        name: j['name'],
        type: j['device_type'],
        osVersion: j['os_version'] ?? '',
        appVersion: j['app_version'] ?? '',
        status: j['status'] ?? 'offline',
        current: j['current'] == true,
        lastSeenAt: j['last_seen_at'] == null ? null : DateTime.parse(j['last_seen_at']).toLocal(),
      );
}

enum MsgStatus { sending, serverReceived, delivered, failed }

class ChatMessage {
  ChatMessage({
    required this.clientId,
    required this.peerId,
    required this.mine,
    required this.type,
    required this.content,
    required this.createdAt,
    this.id,
    this.status = MsgStatus.delivered,
  });
  final String clientId, peerId, type, content;
  final bool mine;
  final DateTime createdAt;
  String? id;
  MsgStatus status;

  /// Builds from a server message object relative to this device.
  factory ChatMessage.fromServer(Map<String, dynamic> j, String selfId) {
    final mine = j['from_device_id'] == selfId;
    return ChatMessage(
      id: j['id'],
      clientId: j['client_msg_id'],
      peerId: mine ? j['to_device_id'] : j['from_device_id'],
      mine: mine,
      type: j['type'],
      content: j['content'],
      createdAt: DateTime.parse(j['created_at']).toLocal(),
      status: !mine || j['delivered_at'] != null ? MsgStatus.delivered : MsgStatus.serverReceived,
    );
  }
}

class Transfer {
  Transfer({
    required this.id,
    required this.sender,
    required this.receiver,
    required this.fileName,
    required this.size,
    required this.status,
    required this.createdAt,
    required this.sha256,
    this.bytes = 0,
    this.error = '',
    this.mode = 'relay',
    this.lanSecret = '',
    this.lanAddrs = const [],
    this.lanPort = 0,
  });
  final String id, sender, receiver, fileName, sha256;

  /// relay | lan — which path carried (or is carrying) the file.
  String mode;

  /// Per-task secret + receiver endpoint for the same-network direct path (from the server).
  final String lanSecret;
  final List<String> lanAddrs;
  final int lanPort;
  final int size;
  final DateTime createdAt;
  String status, error;
  int bytes;

  /// Receiver side: where the finished file was saved. Local only.
  String? savedPath;

  /// Local progress sampling for speed / elapsed time (PRD 4.9).
  DateTime? startedAt, finishedAt;
  double speed = 0; // bytes per second, smoothed

  bool get active => const {'WAITING_ACCEPT', 'ACCEPTED', 'TRANSFERRING', 'VERIFYING'}.contains(status);

  factory Transfer.fromJson(Map<String, dynamic> j) => Transfer(
        id: j['id'],
        sender: j['sender_device_id'],
        receiver: j['receiver_device_id'],
        fileName: j['file_name'],
        size: (j['size'] as num).toInt(),
        sha256: j['sha256'],
        status: j['status'],
        error: j['error'] ?? '',
        mode: j['mode'] ?? 'relay',
        lanSecret: j['lan_secret'] ?? '',
        lanAddrs: ((j['receiver_lan'] as Map?)?['addrs'] as List?)?.cast<String>() ?? const [],
        lanPort: ((j['receiver_lan'] as Map?)?['port'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(j['created_at']).toLocal(),
      );
}
