import 'push_messaging.dart';

/// Web tidak memakai push FCM; inbox dan Socket.IO tetap berjalan.
PushMessaging createPlatformPushMessaging() => const DisabledPushMessaging();
