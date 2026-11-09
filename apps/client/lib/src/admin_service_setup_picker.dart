part of 'admin_service_setup.dart';

class _SetupServicePicker extends StatefulWidget {
  const _SetupServicePicker({
    required this.services,
    required this.catalog,
    required this.selectedId,
    required this.onSelect,
    required this.createAction,
    this.editAction,
  });

  final List<Json> services;
  final Map<String, List<Json>> catalog;
  final String? selectedId;
  final ValueChanged<String>? onSelect;
  final Widget createAction;
  final Widget? editAction;

  @override
  State<_SetupServicePicker> createState() => _SetupServicePickerState();
}

class _SetupServicePickerState extends State<_SetupServicePicker> {
  static const _pageSize = 6;
  final _search = TextEditingController();
  String? _category;
  int _page = 0;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final service in widget.services) {
      final category = serviceCategory(service);
      counts[category] = (counts[category] ?? 0) + 1;
    }
    final category = counts.containsKey(_category) ? _category : null;
    final query = _search.text.trim().toLowerCase();
    final filtered = widget.services.where((service) {
      if (category != null && category != serviceCategory(service)) {
        return false;
      }
      return '${label(service)} ${service['kode'] ?? ''} '
              '${serviceCategoryLabel(service)}'
          .toLowerCase()
          .contains(query);
    }).toList();
    final pageCount = (filtered.length + _pageSize - 1) ~/ _pageSize;
    final page = pageCount == 0 ? 0 : _page.clamp(0, pageCount - 1).toInt();
    final first = page * _pageSize;
    final visible = filtered.skip(first).take(_pageSize).toList();
    final selected = widget.services
        .where((service) => service['id'] == widget.selectedId)
        .firstOrNull;

    final doctors = widget.catalog['/dokter'];
    final rooms = widget.catalog['/loket'];
    final doctorCounts = <Object?, int>{};
    final roomCounts = <Object?, int>{};
    for (final doctor in doctors ?? const <Json>[]) {
      if (doctor['aktif'] != true) continue;
      final linkedServiceIds = rows(doctor['dokterLayanan'])
          .where((link) => link['aktif'] == true)
          .map((link) => link['layananId'])
          .toSet();
      for (final serviceId in linkedServiceIds) {
        doctorCounts[serviceId] = (doctorCounts[serviceId] ?? 0) + 1;
      }
    }
    for (final room in rooms ?? const <Json>[]) {
      if (room['aktif'] != true) continue;
      final serviceId = room['layananId'];
      roomCounts[serviceId] = (roomCounts[serviceId] ?? 0) + 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SetupPanel(
          icon: Icons.medical_services_outlined,
          title: '1. Pilih poliklinik atau layanan',
          subtitle: 'Pilih layanan yang akan dikonfigurasi.',
          badge: _SetupBadge(label: '${widget.services.length} layanan'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onChanged: (_) => setState(() => _page = 0),
                decoration: InputDecoration(
                  labelText: 'Cari nama atau kode layanan',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Bersihkan pencarian',
                          onPressed: () => setState(() {
                            _search.clear();
                            _page = 0;
                          }),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _filterChip(
                    'Semua (${widget.services.length})',
                    null,
                    category,
                  ),
                  for (final entry in counts.entries)
                    _filterChip(
                      '${serviceCategoryLabels[entry.key] ?? entry.key} (${entry.value})',
                      entry.key,
                      category,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(
                    widget.services.isEmpty
                        ? 'Belum ada layanan dalam katalog.'
                        : 'Tidak ada layanan yang cocok dengan filter.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    const gap = 10.0;
                    final twoColumns =
                        constraints.maxWidth >= 480 &&
                        MediaQuery.textScalerOf(context).scale(13) <= 19;
                    final width = twoColumns
                        ? (constraints.maxWidth - gap) / 2
                        : constraints.maxWidth;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final service in visible)
                          SizedBox(
                            width: width,
                            child: _SetupServiceCard(
                              service: service,
                              selected: service['id'] == widget.selectedId,
                              doctorCount: doctors == null
                                  ? null
                                  : doctorCounts[service['id']] ?? 0,
                              roomCount: rooms == null
                                  ? null
                                  : roomCounts[service['id']] ?? 0,
                              onSelect: widget.onSelect == null
                                  ? null
                                  : () => widget.onSelect!('${service['id']}'),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  widget.createAction,
                  if (pageCount > 1) ...[
                    Text(
                      '${first + 1}–${first + visible.length} dari ${filtered.length}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    IconButton(
                      tooltip: 'Halaman layanan sebelumnya',
                      onPressed: page > 0
                          ? () => setState(() => _page = page - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    IconButton(
                      tooltip: 'Halaman layanan berikutnya',
                      onPressed: page + 1 < pageCount
                          ? () => setState(() => _page = page + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        if (selected != null) ...[
          const SizedBox(height: 12),
          _SetupPanel(
            icon: Icons.tune_outlined,
            title: '2. Konfigurasi layanan',
            subtitle: 'Pengaturan pendaftaran untuk ${label(selected)}.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SetupResponsiveRow(
                  minItemWidth: 160,
                  children: [
                    _SetupServiceFact(
                      'Kategori',
                      serviceCategoryLabel(selected),
                    ),
                    _SetupServiceFact(
                      'Mode reservasi',
                      _setupServiceMode(selected),
                    ),
                    _SetupServiceFact(
                      'Prefix antrean',
                      '${selected['prefixAntrean'] ?? '—'}',
                    ),
                    _SetupServiceFact(
                      'Durasi dasar',
                      selected['durasiDasarMenit'] == null
                          ? '—'
                          : '${selected['durasiDasarMenit']} menit',
                    ),
                  ],
                ),
                if (widget.editAction case final editAction?) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: editAction,
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _filterChip(String label, String? value, String? current) =>
      ChoiceChip(
        label: Text(label),
        selected: value == current,
        showCheckmark: false,
        onSelected: (_) => setState(() {
          _category = value;
          _page = 0;
        }),
      );
}

class _SetupServiceCard extends StatelessWidget {
  const _SetupServiceCard({
    required this.service,
    required this.selected,
    required this.doctorCount,
    required this.roomCount,
    required this.onSelect,
  });

  final Json service;
  final bool selected;
  final int? doctorCount, roomCount;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final description = '${service['deskripsi'] ?? ''}'.trim();
    final code = '${service['kode'] ?? ''}'.trim();
    final active = service['aktif'] == true;
    final status = switch (service['aktif']) {
      true => 'Aktif',
      false => 'Nonaktif',
      _ => 'Status belum tersedia',
    };
    final icon = switch (serviceCategory(service)) {
      'APOTEK' => Icons.medication_outlined,
      'LABORATORIUM' => Icons.science_outlined,
      'RADIOLOGI' => Icons.monitor_heart_outlined,
      'KASIR' => Icons.payments_outlined,
      'PENDAFTARAN' || 'REKAM_MEDIS' => Icons.assignment_outlined,
      _ => Icons.medical_services_outlined,
    };
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: selected ? primary : AdminStyle.rule),
    );

    return Semantics(
      selected: selected,
      child: Material(
        color: selected ? Colors.white : AdminStyle.sky,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: primary.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, size: 18, color: primary),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label(service),
                            style: theme.textTheme.titleMedium,
                          ),
                          if (code.isNotEmpty)
                            Text(code, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      selected ? Icons.check_circle : Icons.add_circle_outline,
                      size: 20,
                      color: selected
                          ? primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: [
                    if (selected)
                      _SetupBadge(label: 'Terpilih', color: primary),
                    _SetupBadge(
                      label: status,
                      color: active ? const Color(0xff006259) : null,
                      icon: active ? Icons.check_circle_outline : null,
                    ),
                    _SetupBadge(label: _setupServiceMode(service)),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(height: 1, color: AdminStyle.rule),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      doctorCount == null
                          ? 'Dokter —'
                          : '$doctorCount dokter terkait',
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      roomCount == null ? 'Ruang —' : '$roomCount ruang aktif',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SetupServiceFact extends StatelessWidget {
  const _SetupServiceFact(this.name, this.value);

  final String name, value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AdminStyle.sky,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 3),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}

String _setupServiceMode(Json service) => switch (service['modeReservasi']) {
  'ANTREAN_HARIAN' => 'Walk-in',
  'JANJI_TEMU_DOKTER' => 'Janji temu dokter',
  'HIBRIDA' => 'Hibrida',
  _ => 'Mode belum tersedia',
};
