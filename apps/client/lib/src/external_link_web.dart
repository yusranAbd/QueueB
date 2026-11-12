import 'dart:js_interop';

@JS('window.open')
external JSAny? _windowOpen(String url, String target, String features);

/// Web: WhatsApp opens in a new tab; `tel:` is handed to the device dialer.
Future<bool> openExternalLink(Uri uri) async {
  try {
    if (uri.scheme == 'tel') {
      _windowOpen(uri.toString(), '_self', '');
    } else {
      _windowOpen(uri.toString(), '_blank', 'noopener,noreferrer');
    }
    return true;
  } catch (_) {
    return false;
  }
}
