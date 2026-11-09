part of 'admin_service_setup.dart';

extension _SetupOperations on _AdminServiceSetupState {
  Future<void> unlinkDoctor(Json doctor) async {
    final doctorId = '${doctor['id'] ?? ''}'.trim();
    final serviceId = selectedId;
    if (doctorId.isEmpty ||
        serviceId == null ||
        busy ||
        !widget.repository.active) {
      return;
    }

    final serviceName = label(selected ?? <String, dynamic>{});
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Putuskan hubungan dokter?'),
        content: Text(
          '${label(doctor)} akan dilepas dari $serviceName. '
          'Profil dan akun dokter tidak akan dihapus.\n\n'
          'Jika masih ada sesi praktik mendatang atau reservasi aktif, '
          'hubungan belum bisa diputus sebelum jadwal tersebut ditangani.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.link_off_outlined, size: 17),
            label: const Text('Putuskan Hubungan'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffB42318),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );

    if (!mounted ||
        confirmed != true ||
        busy ||
        !widget.repository.active ||
        selectedId != serviceId) {
      return;
    }

    await _run(() async {
      await widget.repository.api.request(
        'DELETE',
        '/dokter/$doctorId/layanan/$serviceId',
      );
      await widget.repository.refresh(['/dokter', '/jadwal-praktik']);
    });
  }

  Widget doctorStep() {
    final linked = linkedDoctors;
    final available = otherDoctors;
    final hasRoom = rooms.any((room) => room['aktif'] == true);
    final canSchedule = linked.isNotEmpty && hasRoom;
    final dailyQueue = selected?['modeReservasi'] == 'ANTREAN_HARIAN';
    final config = widget.repository.api.config;
    final now = config.now;
    final activeSessions = <Json>[];
    final history = <Json>[];
    for (final session in practices) {
      (adminPracticeCanAddSlot(session, now) ? activeSessions : history).add(
        session,
      );
    }
    activeSessions.sort(compareAdminPracticeStart);
    history.sort((a, b) => compareAdminPracticeStart(b, a));

    Widget sessionRow(Json session, Widget trailing) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _SetupRow(
        icon: Icons.event_outlined,
        title: label(object(object(session['dokterLayanan'])['dokter'])),
        subtitle: [
          if (dateOnly(session['tanggal']).isNotEmpty)
            dateOnly(session['tanggal']),
          _practiceTimeRange(session, config),
          'Ruang: ${label(object(session['loket']))}',
        ].join('\n'),
        trailing: trailing,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        _SetupPanel(
          icon: Icons.medical_services_outlined,
          title: '1. Alokasi dokter',
          subtitle:
              'Hubungkan profil dokter atau tenaga layanan ke poliklinik.',
          badge: _SetupBadge(label: '${linked.length} terhubung'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              if (linked.isEmpty)
                const Text('Belum ada profil aktif yang terhubung.'),
              for (final doctor in linked)
                _SetupRow(
                  icon: Icons.person_outline,
                  title: label(doctor),
                  subtitle: doctor['spesialisasi']?.toString(),
                  trailing: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const _SetupBadge(
                        label: 'Terhubung',
                        color: Color(0xff006259),
                        icon: Icons.check_circle_outline,
                      ),
                      TextButton.icon(
                        onPressed: busy || !widget.repository.active
                            ? null
                            : () => unlinkDoctor(doctor),
                        icon: const Icon(Icons.link_off_outlined, size: 16),
                        label: const Text('Putuskan'),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xffB42318),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              action(
                'Buat profil baru',
                Icons.person_add_alt_1_outlined,
                AdminSetupAction.createDoctor,
              ),
              if (available.isNotEmpty) ...[
                const Divider(height: 1),
                Text(
                  'Profil yang bisa dihubungkan',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final doctor in available)
                  _SetupRow(
                    icon: Icons.person_outline,
                    title: label(doctor),
                    subtitle: doctor['spesialisasi']?.toString(),
                    trailing: action(
                      'Hubungkan',
                      Icons.link,
                      AdminSetupAction.linkDoctor,
                      relatedId: '${doctor['id']}',
                    ),
                  ),
              ],
            ],
          ),
        ),
        _SetupPanel(
          icon: Icons.calendar_month_outlined,
          title: '2. Jadwal praktik dan slot',
          subtitle: dailyQueue
              ? 'Kuota harian mengatur antrean langsung. Tambahkan sesi dan slot bila diperlukan.'
              : 'Atur sesi praktik bertanggal dan slot konsultasi pada setiap sesi.',
          badge: _SetupBadge(label: '${activeSessions.length} sesi aktif'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  action(
                    'Tambah sesi praktik',
                    Icons.edit_calendar_outlined,
                    AdminSetupAction.addPractice,
                    enabled: canSchedule,
                  ),
                  if (!hasRoom)
                    OutlinedButton.icon(
                      onPressed: busy || !widget.repository.active
                          ? null
                          : () => goToStep(3),
                      icon: const Icon(Icons.meeting_room_outlined, size: 17),
                      label: const Text('Siapkan ruang / loket'),
                    ),
                ],
              ),
              if (!canSchedule)
                const Text(
                  'Tambahkan dokter terhubung dan ruang aktif sebelum membuat sesi.',
                ),
              if (activeSessions.isEmpty)
                const Text('Belum ada sesi aktif yang belum berakhir.')
              else
                AdminPagedRows(
                  key: ValueKey('setup-active-practices-$selectedId'),
                  rows: activeSessions,
                  pageSize: 6,
                  builder: (session) => sessionRow(
                    session,
                    action(
                      'Tambah slot',
                      Icons.add,
                      AdminSetupAction.addSlot,
                      relatedId: '${session['id']}',
                    ),
                  ),
                ),
              if (history.isNotEmpty)
                AdminDataGroup(
                  key: PageStorageKey<String>(
                    'setup-practice-history-$selectedId',
                  ),
                  title: 'Riwayat dan sesi nonaktif',
                  subtitle: '${history.length} sesi',
                  children: () => [
                    AdminPagedRows(
                      rows: history,
                      pageSize: 6,
                      builder: (session) => sessionRow(
                        session,
                        _SetupBadge(label: adminPracticeStatus(session, now)),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget hoursStep() {
    final operationalHours = hours;
    final activeDays = operationalHours.where((row) => row['aktif'] == true);
    final config = widget.repository.api.config;
    const days = [
      'Senin',
      'Selasa',
      'Rabu',
      'Kamis',
      'Jumat',
      'Sabtu',
      'Minggu',
    ];
    final today = days[config.now.weekday - 1];
    final todaySchedule = activeDays
        .where((row) => row['hari'] == today.toUpperCase())
        .firstOrNull;
    final capacity = todaySchedule?['kapasitasHarian'];
    final duration = selected?['durasiDasarMenit'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        _SetupPanel(
          icon: Icons.schedule_outlined,
          title: '1. Jam operasional layanan',
          subtitle:
              'Atur jam buka, jam tutup, dan kapasitas tiap hari pelayanan.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              action(
                'Tambah hari operasional',
                Icons.event_repeat,
                AdminSetupAction.addHours,
              ),
              if (operationalHours.isEmpty)
                Text(
                  catalog.containsKey('/jadwal-layanan')
                      ? 'Belum ada jam operasional untuk layanan ini.'
                      : 'Jam operasional belum tersedia di katalog.',
                ),
              for (final row in operationalHours)
                _SetupRow(
                  icon: Icons.schedule_outlined,
                  title: _dayName(row['hari']),
                  subtitle: [
                    _operatingTimeRange(row),
                    if (row['kapasitasHarian'] is num)
                      '${row['kapasitasHarian']} pasien per hari',
                  ].join(' · '),
                  trailing: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _configuredState(row['aktif'] == true),
                      if (row['id'] case final String id when id.isNotEmpty)
                        action(
                          'Ubah',
                          Icons.edit_outlined,
                          AdminSetupAction.editHours,
                          relatedId: id,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        _SetupPanel(
          icon: Icons.bar_chart_outlined,
          title: '2. Kapasitas dan durasi',
          subtitle: 'Kapasitas berlaku untuk hari pelayanan yang dipilih pada jadwal operasional.',
          child: _SetupResponsiveRow(
            minItemWidth: 190,
            children: [
              _SetupRow(
                icon: Icons.groups_outlined,
                title: capacity is num ? '$capacity pasien / hari' : '—',
                subtitle: 'Kapasitas $today',
              ),
              _SetupRow(
                icon: Icons.timelapse_outlined,
                title: duration is num ? '$duration menit' : '—',
                subtitle: 'Durasi dasar layanan',
              ),
              _SetupRow(
                icon: Icons.calendar_today_outlined,
                title: catalog.containsKey('/jadwal-layanan')
                    ? '${activeDays.length} hari'
                    : '—',
                subtitle: 'Hari aktif per minggu',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget roomsStep() {
    final serviceRooms = rooms;
    final openDisplay = widget.onOpenDisplay;
    final devices = _displayAvailable
        ? (catalog[adminDisplayPath] ?? const <Json>[]).where(
            (device) => device['layananId'] == selectedId,
          )
        : const <Json>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        _SetupPanel(
          icon: Icons.meeting_room_outlined,
          title: '1. Pemetaan ruang dan loket',
          subtitle:
              'Siapkan ruang pemeriksaan dan loket yang terhubung ke layanan.',
          badge: _SetupBadge(
            label:
                '${serviceRooms.where((row) => row['aktif'] == true).length} aktif',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              action(
                'Tambah ruang / loket',
                Icons.add,
                AdminSetupAction.addRoom,
              ),
              if (serviceRooms.isEmpty)
                const Text('Belum ada ruang atau loket untuk layanan ini.'),
              for (final room in serviceRooms)
                _SetupRow(
                  icon: Icons.meeting_room_outlined,
                  title: label(room),
                  subtitle: [
                    if (room['kode'] != null) '${room['kode']}',
                    if ('${room['lokasi'] ?? ''}'.trim().isNotEmpty)
                      '${room['lokasi']}',
                  ].join(' · '),
                  trailing: _configuredState(room['aktif'] == true),
                ),
            ],
          ),
        ),
        _SetupPanel(
          icon: Icons.tv_outlined,
          title: '2. Display TV ruang tunggu',
          subtitle:
              'Atur perangkat tampilan yang menayangkan nomor antrean layanan.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              if (!_displayAvailable)
                Text(
                  busy
                      ? 'Memuat perangkat display…'
                      : 'Daftar perangkat belum tersedia.',
                )
              else if (devices.isEmpty)
                const Text('Belum ada perangkat display untuk layanan ini.')
              else
                _SetupResponsiveRow(
                  children: [
                    for (final device in devices)
                      _SetupRow(
                        icon: Icons.tv_outlined,
                        title: label(device),
                        subtitle: device['aktif'] == true
                            ? 'Status katalog: aktif'
                            : 'Status katalog: nonaktif',
                      ),
                  ],
                ),
              if (openDisplay != null)
                OutlinedButton.icon(
                  onPressed: busy || !widget.repository.active
                      ? null
                      : openDisplay,
                  icon: const Icon(Icons.open_in_new, size: 17),
                  label: const Text('Buka Manajemen Display'),
                ),
            ],
          ),
        ),
        _SetupPanel(
          icon: Icons.fact_check_outlined,
          title: '3. Periksa kelengkapan',
          subtitle: 'Tinjau hasil pemeriksaan konfigurasi dari server sebelum mengubah status layanan.',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AdminServiceReadiness(
                catalog: catalog,
                serviceId: selectedId,
                today: widget.repository.api.config.today,
              ),
              action(
                'Periksa / ubah status layanan',
                Icons.settings_outlined,
                AdminSetupAction.editService,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _configuredState(bool active) => _SetupBadge(
    label: active ? 'Aktif' : 'Nonaktif',
    icon: active ? Icons.check_circle_outline : Icons.info_outline,
    color: active ? const Color(0xff006259) : null,
  );

  String _practiceTimeRange(Json row, AppConfig config) {
    final start = config.instantLabel(row['mulaiPada']);
    final end = config.instantLabel(row['selesaiPada']);
    final day = dateOnly(row['tanggal']);
    if (start == '—' || end == '—') return 'Jam sesi belum tersedia';
    if (day.isNotEmpty &&
        start.startsWith('$day ') &&
        end.startsWith('$day ')) {
      return '${start.substring(11)} – ${end.substring(11)}';
    }
    return '$start – $end';
  }

  String _operatingTimeRange(Json row) {
    final open = clockOnly(row['jamBuka']);
    final close = clockOnly(row['jamTutup']);
    return open.isEmpty || close.isEmpty
        ? 'Jam belum tersedia'
        : '$open – $close';
  }

  String _dayName(Object? value) {
    final day = '${value ?? ''}'.trim();
    return day.isEmpty
        ? 'Hari belum tersedia'
        : day[0] + day.substring(1).toLowerCase();
  }
}
