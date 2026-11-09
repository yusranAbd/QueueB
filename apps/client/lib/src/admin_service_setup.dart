import 'dart:async';

import 'package:flutter/material.dart';

import 'admin_data.dart' show AdminDataGroup, AdminPagedRows;
import 'admin_practice_availability.dart';
import 'admin_ui.dart';
import 'config.dart';
import 'queueb_palette.dart';
import 'queueb_feedback.dart';
import 'admin_service_readiness.dart';
import 'service_category.dart';
import 'features/admin/data/admin_catalog_repository.dart';
import 'features/admin/models/admin_display_models.dart';

part 'admin_service_setup_operations.dart';
part 'admin_service_setup_picker.dart';

/// A single place to complete existing ADMIN configuration operations.
/// Each action still uses the existing API/Cubit and confirms a separate save.
/// This view never batches POST requests or treats a partial setup as atomic.
enum AdminSetupAction {
  createService,
  editService,
  addRoom,
  addHours,
  editHours,
  createDoctor,
  linkDoctor,
  addPractice,
  addSlot,
}

typedef AdminSetupHandler = Future<void> Function(
  AdminSetupAction action,
  String? serviceId,
  String? relatedId,
);

class AdminServiceSetup extends StatefulWidget {
  const AdminServiceSetup({
    super.key,
    required this.repository,
    required this.onAction,
    this.onClose,
    this.onOpenDisplay,
    this.onRefresh,
    this.onBusyChanged,
  });

  final AdminCatalogRepository repository;
  final AdminSetupHandler onAction;
  final VoidCallback? onClose, onOpenDisplay;
  final Future<void> Function()? onRefresh;
  final ValueChanged<bool>? onBusyChanged;

  @override
  State<AdminServiceSetup> createState() => _AdminServiceSetupState();
}

class _AdminServiceSetupState extends State<AdminServiceSetup> {
  static const steps = [
    'Pilih Poliklinik',
    'Dokter & Jadwal',
    'Jam & Kapasitas',
    'Loket & Display TV',
  ];

  final _scroll = ScrollController();
  int step = 0;
  bool busy = false;
  bool _displayAvailable = false;
  String? selectedId;
  String? error;

  Map<String, List<Json>> get catalog => widget.repository.snapshot.collections;
  List<Json> get services => catalog['/layanan'] ?? const [];
  Json? get selected =>
      services.where((r) => r['id'] == selectedId).firstOrNull;
  List<Json> get rooms => (catalog['/loket'] ?? const [])
      .where((r) => r['layananId'] == selectedId)
      .toList();
  List<Json> get hours => (catalog['/jadwal-layanan'] ?? const [])
      .where((r) => r['layananId'] == selectedId)
      .toList();
  List<Json> get linkedDoctors => (catalog['/dokter'] ?? const [])
      .where(
        (d) =>
            d['aktif'] == true &&
            rows(d['dokterLayanan'])
                .any((l) => l['layananId'] == selectedId && l['aktif'] == true),
      )
      .toList();
  List<Json> get otherDoctors => (catalog['/dokter'] ?? const [])
      .where(
        (d) =>
            d['aktif'] == true &&
            !rows(d['dokterLayanan'])
                .any((l) => l['layananId'] == selectedId && l['aktif'] == true),
      )
      .toList();
  List<Json> get practices => (catalog['/jadwal-praktik'] ?? const [])
      .where(
        (p) =>
            object(p['dokterLayanan'])['layananId'] == selectedId ||
            object(object(p['dokterLayanan'])['layanan'])['id'] == selectedId,
      )
      .toList();

  Future<void> _run(Future<void> Function() work) async {
    if (busy || !widget.repository.active) return;
    setState(() {
      busy = true;
      error = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      await work();
    } catch (e) {
      if (mounted) error = 'Operasi belum selesai: $e';
    } finally {
      if (mounted) {
        setState(() => busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> perform(AdminSetupAction action, {String? relatedId}) =>
      _run(() async {
        final before = services.map((r) => '${r['id']}').toSet();
        await widget.onAction(action, selectedId, relatedId);
        if (!mounted || !widget.repository.active) return;
        if (action == AdminSetupAction.createService) {
          final created = services
              .where((r) => !before.contains('${r['id']}'))
              .toList();
          if (created.length == 1) selectedId = '${created.first['id']}';
        }
      });

  Widget action(
    String title,
    IconData icon,
    AdminSetupAction command, {
    String? relatedId,
    bool enabled = true,
  }) => OutlinedButton.icon(
    onPressed: !enabled || busy || !widget.repository.active
        ? null
        : () => perform(command, relatedId: relatedId),
    icon: Icon(icon, size: 17),
    label: Text(title),
  );

  void goToStep(int next) {
    if (busy || next == step || (next > 0 && selected == null)) return;
    setState(() => step = next);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (next == 3) unawaited(_run(_refreshDisplays));
  }

  Future<void> _refreshDisplays() async {
    _displayAvailable = false;
    await widget.repository.refresh([adminDisplayPath]);
    _displayAvailable = catalog.containsKey(adminDisplayPath);
  }

  void _close() {
    if (busy) return;
    if (widget.onClose case final close?) {
      close();
    } else {
      Navigator.maybePop(context);
    }
  }

  void _showGuide() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Panduan konfigurasi'),
        content: const SingleChildScrollView(
          child: Text(
            '1. Pilih poliklinik atau layanan yang akan dikelola.\n'
            '2. Hubungkan dokter, buat sesi praktik, dan atur slot jika diperlukan.\n'
            '3. Atur jam operasional dan kapasitas harian.\n'
            '4. Periksa ruang atau loket dan kelengkapan konfigurasi. Buka Manajemen Display untuk perangkat TV.\n\n'
            'Simpan perubahan pada tiap formulir. Jika belum ada ruang aktif, '
            'siapkan ruang di langkah 4 sebelum membuat sesi praktik.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tutup panduan'),
          ),
        ],
      ),
    );
  }

  String _count(String path, int value) =>
      catalog.containsKey(path) ? '$value' : '—';

  Widget _overview(Json? service) {
    final config = widget.repository.api.config;
    final now = config.now;
    final today = DateTime.tryParse(dateOnly(config.today));
    const weekdays = [
      'SENIN',
      'SELASA',
      'RABU',
      'KAMIS',
      'JUMAT',
      'SABTU',
      'MINGGU',
    ];
    final activeHours = hours.where((h) => h['aktif'] == true);
    final todayHours = today == null
        ? null
        : activeHours
              .where((h) => h['hari'] == weekdays[today.weekday - 1])
              .firstOrNull;
    final capacity = todayHours?['kapasitasHarian'];
    return _SetupPanel(
      icon: Icons.assignment_outlined,
      title: 'Ringkasan konfigurasi',
      badge: _SetupBadge(label: 'Langkah ${step + 1}/4'),
      child: service == null
          ? const Text('Pilih layanan untuk melihat rincian konfigurasinya.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SetupRow(
                  icon: Icons.local_hospital_outlined,
                  title: label(service),
                  subtitle:
                      '${service['kode'] ?? '—'} · ${serviceCategoryLabel(service)}',
                  trailing: _SetupBadge(
                    label: service['aktif'] == true ? 'Aktif' : 'Nonaktif',
                    color: service['aktif'] == true
                        ? const Color(0xff176449)
                        : null,
                  ),
                ),
                const SizedBox(height: 10),
                _summaryLine('Mode reservasi', _setupServiceMode(service)),
                _summaryLine(
                  'Dokter terhubung',
                  _count('/dokter', linkedDoctors.length),
                ),
                _summaryLine(
                  'Sesi praktik aktif',
                  _count(
                    '/jadwal-praktik',
                    practices
                        .where((r) => adminPracticeCanAddSlot(r, now))
                        .length,
                  ),
                ),
                _summaryLine(
                  'Hari operasional',
                  _count(
                    '/jadwal-layanan',
                    activeHours.map((r) => r['hari']).toSet().length,
                  ),
                ),
                _summaryLine(
                  'Ruang / loket aktif',
                  _count(
                    '/loket',
                    rooms.where((r) => r['aktif'] == true).length,
                  ),
                ),
                const SizedBox(height: 6),
                _SetupRow(
                  icon: Icons.groups_outlined,
                  title: capacity is num ? '$capacity pasien' : '—',
                  subtitle: 'Kapasitas hari ini',
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AdminServiceReadiness(
                    catalog: catalog,
                    serviceId: selectedId,
                    today: config.today,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _summaryLine(String title, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(color: QueueBPalette.muted),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Widget _stepBar() => Container(
    decoration: _setupPanelDecoration,
    padding: const EdgeInsets.all(10),
    child: LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
        final columns = box.maxWidth >= 704 * scale
            ? 4
            : box.maxWidth >= 360 * scale
            ? 2
            : 1;
        final width = (box.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < steps.length; i++)
              SizedBox(width: width, child: _stepTile(i)),
          ],
        );
      },
    ),
  );

  Widget _stepTile(int index) {
    final active = index == step;
    final enabled = !busy && (index == 0 || selected != null);
    final foreground = active
        ? Colors.white
        : enabled
        ? QueueBPalette.ink
        : QueueBPalette.muted;
    final borderRadius = BorderRadius.circular(9);
    return Semantics(
      button: true,
      selected: active,
      enabled: enabled,
      child: Material(
        color: active ? QueueBPalette.hero : AdminStyle.sky,
        borderRadius: borderRadius,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: enabled ? () => goToStep(index) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Container(
                  alignment: Alignment.center,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: active
                        ? Colors.white
                        : Colors.white.withValues(alpha: .75),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: QueueBPalette.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        active
                            ? 'LANGKAH ${index + 1} · AKTIF'
                            : 'LANGKAH ${index + 1}',
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.35,
                          color: foreground,
                        ),
                      ),
                      Text(
                        steps[index],
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => Container(
    decoration: _setupPanelDecoration,
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SetupBadge(
          label: 'MODUL OPERASIONAL',
          icon: Icons.layers_outlined,
        ),
        const SizedBox(height: 8),
        AdminPageHeading(
          title: 'Kelola Layanan Terpadu',
          subtitle: 'Konfigurasi poliklinik, jadwal dokter, kapasitas, dan loket dalam satu alur.',
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : _showGuide,
                icon: const Icon(Icons.help_outline, size: 17),
                label: const Text('Panduan Wizard'),
              ),
              if (widget.onRefresh case final refresh?)
                OutlinedButton.icon(
                  onPressed: busy || !widget.repository.active
                      ? null
                      : () => _run(() async {
                          await refresh();
                          if (mounted && step == 3) await _refreshDisplays();
                        }),
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('Muat ulang'),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _content(Json? service) {
    if (step == 0) {
      return _SetupServicePicker(
        services: services,
        catalog: catalog,
        selectedId: selectedId,
        onSelect: busy || !widget.repository.active
            ? null
            : (id) => setState(() => selectedId = id),
        createAction: action(
          'Tambah layanan',
          Icons.add,
          AdminSetupAction.createService,
        ),
        editAction: service == null
            ? null
            : action(
                'Ubah layanan',
                Icons.edit_outlined,
                AdminSetupAction.editService,
              ),
      );
    }
    if (service == null) {
      return _SetupPanel(
        icon: Icons.info_outline,
        title: 'Layanan belum dipilih',
        child: TextButton(
          onPressed: busy ? null : () => goToStep(0),
          child: const Text('Pilih layanan'),
        ),
      );
    }
    return switch (step) {
      1 => doctorStep(),
      2 => hoursStep(),
      _ => roomsStep(),
    };
  }

  Widget _footer(Json? service) => Container(
    decoration: _setupPanelDecoration,
    padding: const EdgeInsets.all(10),
    child: LayoutBuilder(
      builder: (context, box) {
        final buttons = Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: step == 0 || busy ? null : () => goToStep(step - 1),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Sebelumnya'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: QueueBPalette.hero,
              ),
              onPressed: busy || service == null
                  ? null
                  : step == steps.length - 1
                  ? _close
                  : () => goToStep(step + 1),
              icon: Icon(
                step == steps.length - 1 ? Icons.check : Icons.arrow_forward,
                size: 16,
              ),
              label: Text(step == steps.length - 1 ? 'Tutup' : 'Selanjutnya'),
            ),
          ],
        );
        final info = Text(
          service == null
              ? 'Pilih layanan untuk melanjutkan.'
              : 'Perubahan disimpan dari setiap formulir.',
          style: Theme.of(context).textTheme.bodySmall,
        );
        if (box.maxWidth < 560 ||
            MediaQuery.textScalerOf(context).scale(13) > 17) {
          return Align(alignment: Alignment.centerRight, child: buttons);
        }
        return Row(
          children: [
            Expanded(child: info),
            const SizedBox(width: 12),
            buttons,
          ],
        );
      },
    ),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.repository,
    builder: (context, _) => LayoutBuilder(
      builder: (context, bounds) {
        final service = selected;
        final wide =
            bounds.maxWidth >= 830 &&
            MediaQuery.textScalerOf(context).scale(13) <= 17;
        final gutter = bounds.maxWidth < 480 ? 12.0 : 20.0;
        // Isolasi repaint konten wizard ketika langkah atau layanan diganti.
        final content = RepaintBoundary(
          key: ValueKey('admin-setup-content-$step-$selectedId'),
          child: _content(service),
        );
        final overview = _overview(service);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (busy) const LinearProgressIndicator(minHeight: 3),
            Expanded(
              child: Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  key: const PageStorageKey('admin-service-setup'),
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(gutter, 14, gutter, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Operasional / Kelola Layanan Terpadu / Langkah ${step + 1}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      _header(),
                      const SizedBox(height: 12),
                      _stepBar(),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        QueueBPopupNotice(
                          error!,
                          kind: QueueBFeedbackKind.error,
                        ),
                      ],
                      if (step > 0 && service != null) ...[
                        const SizedBox(height: 12),
                        _SetupRow(
                          icon: Icons.local_hospital_outlined,
                          title:
                              '${label(service)} · ${service['kode'] ?? '—'}',
                          subtitle:
                              '${_setupServiceMode(service)} · ${serviceCategoryLabel(service)}',
                          trailing: TextButton.icon(
                            onPressed: busy ? null : () => goToStep(0),
                            icon: const Icon(Icons.swap_horiz, size: 17),
                            label: const Text('Ganti layanan'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (wide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: content),
                            const SizedBox(width: 14),
                            SizedBox(
                              width: bounds.maxWidth >= 1050 ? 314 : 270,
                              child: overview,
                            ),
                          ],
                        )
                      else ...[
                        content,
                        const SizedBox(height: 12),
                        overview,
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 12),
              child: _footer(service),
            ),
          ],
        );
      },
    ),
  );
}

final _setupPanelDecoration = BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.circular(12),
  border: Border.all(color: AdminStyle.rule),
);

class _SetupPanel extends StatelessWidget {
  const _SetupPanel({
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? badge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Container(
      decoration: _setupPanelDecoration,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SetupIcon(icon: icon),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.titleMedium),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!, style: theme.bodySmall),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (badge != null) ...[
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: badge!),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SetupIcon extends StatelessWidget {
  const _SetupIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      color: AdminStyle.sky,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(icon, color: QueueBPalette.primary, size: 20),
  );
}

class _SetupBadge extends StatelessWidget {
  const _SetupBadge({required this.label, this.color, this.icon});

  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? QueueBPalette.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ink.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 3,
          children: [
            if (icon != null) Icon(icon, size: 13, color: ink),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupRow extends StatelessWidget {
  const _SetupRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AdminStyle.sky,
      borderRadius: BorderRadius.circular(9),
    ),
    padding: const EdgeInsets.all(10),
    child: LayoutBuilder(
      builder: (context, box) {
        final identity = Row(
          children: [
            Icon(icon, size: 19, color: QueueBPalette.primary),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
        if (trailing == null) return identity;
        if (box.maxWidth < 400 ||
            MediaQuery.textScalerOf(context).scale(13) > 17) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [identity, const SizedBox(height: 6), trailing!],
          );
        }
        return Row(
          children: [
            Expanded(child: identity),
            const SizedBox(width: 10),
            Flexible(child: trailing!),
          ],
        );
      },
    ),
  );
}

class _SetupResponsiveRow extends StatelessWidget {
  const _SetupResponsiveRow({required this.children, this.minItemWidth = 240});

  final List<Widget> children;
  final double minItemWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = 10.0;
      final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
      final count = ((box.maxWidth + gap) / (minItemWidth * scale + gap))
          .floor()
          .clamp(1, 3);
      final width = (box.maxWidth - (count - 1) * gap) / count;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}
