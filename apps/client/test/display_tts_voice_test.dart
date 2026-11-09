import 'package:flutter_test/flutter_test.dart';
import 'package:queueb_client/src/features/display/services/display_audio_controller.dart';

void main() {
  test('prefers exact id-ID over looser Indonesian locales', () {
    final voice = pickIndonesianVoice([
      {'name': 'English', 'locale': 'en-US'},
      {'name': 'Loose', 'locale': 'id'},
      {'name': 'Exact', 'locale': 'id-ID'},
    ]);
    expect(voice?['name'], 'Exact');
  });

  test('accepts Android Chrome id_ID, id and legacy in-ID', () {
    expect(
      pickIndonesianVoice([
        {'name': 'A', 'locale': 'id_ID'},
      ])?['name'],
      'A',
    );
    expect(
      pickIndonesianVoice([
        {'name': 'B', 'locale': 'in-ID'},
      ])?['name'],
      'B',
    );
  });

  test('returns null for empty or non-Indonesian voice lists', () {
    expect(pickIndonesianVoice([]), isNull);
    expect(
      pickIndonesianVoice([
        {'name': 'English', 'locale': 'en-US'},
      ]),
      isNull,
    );
  });
}
