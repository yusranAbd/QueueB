import 'session_store.dart';

/// Native platforms have no browser tab storage.
TabStorage? browserTabStorage() => null;
