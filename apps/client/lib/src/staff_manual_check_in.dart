import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'config.dart';
import 'mobile_ui.dart';
import 'staff_qr_scanner.dart';

final _queueNumber = RegExp(r'^[A-Z0-9]{1,5}-\d{1,6}$');

String _statusLabel(String status) => switch (status) {
  'DIPESAN' => 'Dipesan, belum check-in',
  'CHECK_IN' || 'MENUNGGU' => 'Sudah check-in',
  'DIPANGGIL' => 'Sedang dipanggil',
  'DILAYANI' => 'Sedang dilayani',
  'SELESAI' => 'Selesai',
  'DILEWATI' => 'Dilewati',
  'DIBATALKAN' => 'Dibatalkan',
  _ => status,
};

/// Check-in manual untuk pasien tanpa QR (mis. tanpa HP). Petugas mencari tiket
/// hari ini lewat nomor antrean, mencocokkan nama yang disamarkan dengan pasien
/// di depannya, lalu check-in. Server memvalidasi penugasan, layanan, tanggal dan
/// jam pelayanan, dan mencatat audit check-in manual.
class StaffManualCheckIn extends StatefulWidget {
  const StaffManualCheckIn({
    super.key,
    required this.lookup,
    required this.checkIn,
    this.onCheckedIn,
  });
  final Future<Json> Function(String number) lookup;
  final Future<Json> Function(String ticketId) checkIn;
  final VoidCallback? onCheckedIn;

  @override
  State<StaffManualCheckIn> createState() => _StaffManualCheckInState();
}

class _StaffManualCheckInState extends State<StaffManualCheckIn> {
  final input = TextEditingController();
  bool busy = false;
  String? error;
  Json? found, done;

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  String get number => input.text.trim().toUpperCase();

  String _message(Object e) => e is ApiException && e.message.isNotEmpty
      ? e.message
      : 'Proses belum dapat dipastikan. Periksa daftar antrean sebelum mencoba kembali.';

  Future<void> search() async {
    if (busy) return;
    if (!_queueNumber.hasMatch(number)) {
      setState(() {
        error = 'Masukkan nomor antrean dengan format seperti A-025.';
        found = done = null;
      });
      return;
    }
    setState(() {
      busy = true;
      error = null;
      found = done = null;
    });
    try {
      final result = await widget.lookup(number);
      if (mounted) setState(() => found = result);
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> confirm() async {
    final ticket = found;
    if (busy || ticket == null || ticket['dapatCheckInManual'] != true) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.checkIn('${ticket['tiketId']}');
      if (!mounted) return;
      setState(() {
        done = result;
        found = null;
        input.clear();
      });
      widget.onCheckedIn?.call();
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _ticket(Json ticket) {
    final allowed = ticket['dapatCheckInManual'] == true;
    final reason = ticket['alasan'];
    final service = object(ticket['layanan']);
    return Container(
      key: const ValueKey('staff-manual-ticket'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: QueueBStyle.muted.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${ticket['nomorAntrean']} · ${_statusLabel('${ticket['status']}')}',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text('Pasien: ${ticket['namaPasien'] ?? '—'}'),
          if (service['nama'] != null)
            Text(
              '${service['nama']}'
              '${ticket['jenisAntrean'] == 'JANJI_TEMU' ? ' · Janji temu' : ''}',
              style: const TextStyle(fontSize: 12, color: QueueBStyle.muted),
            ),
          const SizedBox(height: 8),
          if (allowed)
            const Text(
              'Cocokkan nama dengan pasien di depan Anda sebelum check-in.',
              style: TextStyle(fontSize: 12, color: QueueBStyle.muted),
            )
          else
            MobileNotice(
              reason is String && reason.isNotEmpty
                  ? reason
                  : 'Tiket ini belum dapat di-check-in manual.',
              error: true,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ticket = found;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('Check-in tanpa QR'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('staff-manual-number'),
                  controller: input,
                  enabled: !busy,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.search,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
                    LengthLimitingTextInputFormatter(12),
                  ],
                  onSubmitted: (_) => search(),
                  decoration: const InputDecoration(
                    labelText: 'Nomor antrean',
                    hintText: 'Contoh: A-025',
                    prefixIcon: Icon(Icons.confirmation_number_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                if (busy) const LinearProgressIndicator(),
                if (done != null) StaffScanResult(result: done!),
                if (error != null) MobileNotice(error!, error: true),
                if (ticket != null) _ticket(ticket),
                const SizedBox(height: 8),
                const Text(
                  'Hanya tiket hari ini pada layanan loket Anda. Check-in tercatat atas nama petugas.',
                  style: TextStyle(fontSize: 12, color: QueueBStyle.muted),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Tutup'),
          ),
          if (ticket != null && ticket['dapatCheckInManual'] == true)
            FilledButton(
              key: const ValueKey('staff-manual-confirm'),
              onPressed: busy ? null : confirm,
              child: const Text('Check-in & masuk antrean'),
            )
          else
            FilledButton(
              key: const ValueKey('staff-manual-search'),
              onPressed: busy ? null : search,
              child: const Text('Cari'),
            ),
        ],
      ),
    );
  }
}
