import 'config.dart';

enum _PracticeStatus { upcoming, ongoing, ended, inactive, unknown }

DateTime? _instant(Object? value) {
  final parsed = DateTime.tryParse('$value');
  return parsed?.isUtc == true ? parsed : null;
}

_PracticeStatus _status(Json session, DateTime now) {
  final link = object(session['dokterLayanan']);
  if (session['aktif'] != true ||
      link['aktif'] == false ||
      object(link['dokter'])['aktif'] == false ||
      object(link['layanan'])['aktif'] == false ||
      object(session['loket'])['aktif'] == false) {
    return _PracticeStatus.inactive;
  }
  final start = _instant(session['mulaiPada']);
  final end = _instant(session['selesaiPada']);
  if (start == null || end == null || !end.isAfter(start)) {
    return _PracticeStatus.unknown;
  }
  if (!end.isAfter(now)) return _PracticeStatus.ended;
  return start.isAfter(now)
      ? _PracticeStatus.upcoming
      : _PracticeStatus.ongoing;
}

/// Filters administrative creation choices without removing catalog history.
bool adminPracticeCanAddSlot(Json session, DateTime now) =>
    switch (_status(session, now)) {
      _PracticeStatus.upcoming || _PracticeStatus.ongoing => true,
      _ => false,
    };

String adminPracticeStatus(Json session, DateTime now) =>
    switch (_status(session, now)) {
      _PracticeStatus.upcoming => 'Akan datang',
      _PracticeStatus.ongoing => 'Berlangsung',
      _PracticeStatus.ended => 'Berakhir',
      _PracticeStatus.inactive => 'Nonaktif',
      _PracticeStatus.unknown => 'Waktu belum diketahui',
    };

int compareAdminPracticeStart(Json a, Json b) {
  final startA = _instant(a['mulaiPada']);
  final startB = _instant(b['mulaiPada']);
  final order = startA == null
      ? (startB == null ? 0 : 1)
      : (startB == null ? -1 : startA.compareTo(startB));
  return order == 0 ? '${a['id']}'.compareTo('${b['id']}') : order;
}
