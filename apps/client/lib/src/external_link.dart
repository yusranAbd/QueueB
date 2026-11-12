/// Native builds have no URL launcher plugin; callers fall back to copying.
Future<bool> openExternalLink(Uri uri) async => false;
