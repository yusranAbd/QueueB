import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'queueb_feedback.dart';

import 'config.dart';
import 'doctor_professional.dart';
import 'external_link.dart'
    if (dart.library.js_interop) 'external_link_web.dart';
import 'mobile_ui.dart';
import 'patient_design.dart';
import 'patient_home_v7.dart';
import 'patient_home_v8.dart';

/// Clinic contact numbers shown to patients. The clinic ambulance number was
/// provided by the clinic.
abstract final class ClinicContacts {
  static const ambulanceDisplay = '0813-5611-2805';
  static final ambulanceWhatsApp = Uri.parse('https://wa.me/6281356112805');
}

/// A view of the existing USER catalog owned by PatientRepository. No request,
/// subscription, account snapshot, clinical content or second owner lives here.
class PatientInformation extends StatelessWidget {
  const PatientInformation({
    super.key,
    required this.services,
    required this.hours,
    required this.date,
    required this.hoursAvailable,
    required this.loading,
    required this.onRefresh,
    this.doctors = const [],
    this.config,
    this.error,
    this.hoursError,
  });
  final List<Json> services, hours, doctors;
  final String date;
  final bool hoursAvailable, loading;
  final String? error, hoursError;
  final VoidCallback? onRefresh;

  /// Resolves doctor photo URLs; avatars fall back to an icon without it.
  final AppConfig? config;

  /// Active doctors linked to [serviceId] through an active `dokterLayanan`.
  static List<Json> doctorsFor(List<Json> doctors, String serviceId) {
    final linked = doctors.where((doctor) {
      if (doctor['aktif'] == false) return false;
      return rows(doctor['dokterLayanan']).any(
        (link) =>
            link['aktif'] != false &&
            '${link['layananId'] ?? object(link['layanan'])['id']}' ==
                serviceId,
      );
    }).toList()..sort((a, b) => label(a).compareTo(label(b)));
    return linked;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      // Patient content is centred at 480 logical px, with a 16 px gutter.
      final side = math.max(16.0, (bounds.maxWidth - 480) / 2);
      return ListView.builder(
        key: const PageStorageKey('patient-information'),
        padding: EdgeInsets.fromLTRB(side, 16, side, 24),
        itemCount: 3 + (services.isEmpty ? 1 : services.length),
        itemBuilder: (context, index) {
          if (index == 0) return _header();
          if (index == 1) return const _ClinicContactCard();
          if (index == 2) {
            return const Padding(
              padding: EdgeInsets.fromLTRB(2, 20, 2, 10),
              child: Text(
                'Layanan klinik',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: PatientDesign.ink,
                ),
              ),
            );
          }
          if (services.isEmpty) {
            return const EmptyState(
              text: 'Belum ada informasi layanan yang dapat ditampilkan.',
            );
          }
          final service = services[index - 3];
          return _ServiceInformationCard(
            key: ValueKey(('information', '${service['id']}')),
            service: service,
            doctors: doctorsFor(doctors, '${service['id']}'),
            hours: patientServiceHours(
              hours,
              '${service['id']}',
              date,
              available: hoursAvailable,
            ),
            config: config,
          );
        },
      );
    },
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Informasi layanan',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w800,
                  color: PatientDesign.ink,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Muat ulang informasi',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Kontak darurat, layanan, dokter, dan jam operasional klinik.',
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            color: PatientDesign.muted,
          ),
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
        if (error != null)
          QueueBPopupNotice(error!, kind: QueueBFeedbackKind.error),
        if (hoursError != null)
          QueueBPopupNotice(hoursError!, kind: QueueBFeedbackKind.error),
      ],
    ),
  );
}

/// Opens [uri]; where no launcher exists, copies [copyText] and says so.
Future<void> _contact(BuildContext context, Uri uri, String copyText) async {
  if (await openExternalLink(uri)) return;
  await Clipboard.setData(ClipboardData(text: copyText));
  if (!context.mounted) return;
  QueueBFeedback.show(context, 'Nomor $copyText disalin.');
}

class _ClinicContactCard extends StatelessWidget {
  const _ClinicContactCard();

  @override
  Widget build(BuildContext context) => Card(
    key: const ValueKey('clinic-contact'),
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Kontak darurat',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: PatientDesign.ink,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Hubungi bila membutuhkan ambulans atau pertolongan segera.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: PatientDesign.muted,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: PatientDesign.danger.withValues(alpha: .07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: PatientDesign.danger.withValues(alpha: .22),
              ),
            ),
            child: const _AmbulanceContact(),
          ),
        ],
      ),
    ),
  );
}

class _AmbulanceContact extends StatelessWidget {
  const _AmbulanceContact();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      const details = Row(
        children: [
          Icon(Icons.emergency_outlined, color: PatientDesign.danger, size: 26),
          SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ambulans klinik',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: PatientDesign.danger,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  ClinicContacts.ambulanceDisplay,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: PatientDesign.ink,
                  ),
                ),
                Text(
                  'WhatsApp',
                  style: TextStyle(fontSize: 12, color: PatientDesign.muted),
                ),
              ],
            ),
          ),
        ],
      );
      final action = FilledButton.icon(
        key: const ValueKey('ambulance-whatsapp'),
        style: FilledButton.styleFrom(
          backgroundColor: PatientDesign.danger,
          minimumSize: const Size(0, 44),
        ),
        onPressed: () => _contact(
          context,
          ClinicContacts.ambulanceWhatsApp,
          ClinicContacts.ambulanceDisplay,
        ),
        // Only Web can open WhatsApp; native builds copy the number, so the
        // label must say what actually happens.
        icon: const Icon(
          kIsWeb ? Icons.chat_outlined : Icons.copy_outlined,
          size: 18,
        ),
        label: const Text(kIsWeb ? 'Chat WhatsApp' : 'Salin nomor'),
      );
      // Side by side only when both fit; otherwise the action takes a full row.
      final inline =
          bounds.maxWidth >= 320 &&
          MediaQuery.textScalerOf(context).scale(14) <= 17;
      return inline
          ? Row(
              children: [
                const Expanded(child: details),
                const SizedBox(width: 12),
                action,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [details, const SizedBox(height: 10), action],
            );
    },
  );
}

class _ServiceInformationCard extends StatelessWidget {
  const _ServiceInformationCard({
    super.key,
    required this.service,
    required this.doctors,
    required this.hours,
    required this.config,
  });
  final Json service;
  final List<Json> doctors;
  final String hours;
  final AppConfig? config;

  @override
  Widget build(BuildContext context) {
    final category = homeServiceCategory(service),
        accent = PatientHomeV8Style.accent(category);
    final mode = switch (service['modeReservasi']) {
      'ANTREAN_HARIAN' => 'Antrean harian',
      'JANJI_TEMU_DOKTER' => 'Janji temu dokter',
      'HIBRIDA' => 'Antrean harian & janji temu',
      _ => 'Mode reservasi belum tersedia',
    };
    final description = '${service['deskripsi'] ?? ''}'.trim();
    final clinic = service['kategori'] == 'POLIKLINIK';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    PatientServiceAccent.icon(category),
                    color: accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label(service),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: PatientDesign.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: PatientDesign.soft,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          mode,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: PatientDesign.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              description.isEmpty
                  ? 'Deskripsi layanan belum tersedia.'
                  : description,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: description.isEmpty
                    ? PatientDesign.muted
                    : PatientDesign.ink,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: PatientDesign.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.schedule_outlined,
                    size: 18,
                    color: PatientDesign.muted,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Jam operasional hari ini',
                      style: TextStyle(
                        fontSize: 12,
                        color: PatientDesign.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      hours,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: PatientDesign.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              clinic ? 'Dokter yang praktik' : 'Tenaga kesehatan',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: PatientDesign.ink,
              ),
            ),
            const SizedBox(height: 8),
            if (doctors.isEmpty)
              Text(
                clinic ? 'Belum ada dokter yang terdaftar pada layanan ini.' : 'Belum ada tenaga kesehatan yang terdaftar pada layanan ini.',
                style: const TextStyle(
                  fontSize: 13,
                  color: PatientDesign.muted,
                ),
              )
            else
              for (final (index, doctor) in doctors.indexed) ...[
                if (index > 0) const SizedBox(height: 8),
                _DoctorRow(doctor: doctor, config: config),
              ],
          ],
        ),
      ),
    );
  }
}

class _DoctorRow extends StatelessWidget {
  const _DoctorRow({required this.doctor, required this.config});
  final Json doctor;
  final AppConfig? config;

  @override
  Widget build(BuildContext context) {
    final specialty = '${doctor['spesialisasi'] ?? ''}'.trim();
    final avatar = config == null
        ? const CircleAvatar(
            radius: 18,
            backgroundColor: PatientDesign.soft,
            child: Icon(
              Icons.person_outline_rounded,
              size: 18,
              color: PatientDesign.primary,
            ),
          )
        : ProfessionalDoctorAvatar(
            config: config!,
            photo: doctor['fotoProfil'],
            radius: 18,
          );
    return Row(
      key: ValueKey(('information-doctor', '${doctor['id']}')),
      children: [
        avatar,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label(doctor),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: PatientDesign.ink,
                ),
              ),
              if (specialty.isNotEmpty)
                Text(
                  specialty,
                  style: const TextStyle(
                    fontSize: 12,
                    color: PatientDesign.muted,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
