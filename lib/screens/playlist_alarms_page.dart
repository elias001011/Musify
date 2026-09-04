/*
 *     Copyright (C) 2026 Valeri Gokadze
 *
 *     Musify is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 */

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:material_ui/material_ui.dart';
import 'package:musify/extensions/l10n.dart';
import 'package:musify/models/playlist_alarm.dart';
import 'package:musify/services/playlist_alarm_service.dart';
import 'package:musify/utilities/flutter_toast.dart';
import 'package:musify/widgets/mini_player_bottom_space.dart';

class PlaylistAlarmsPage extends StatefulWidget {
  const PlaylistAlarmsPage({super.key});

  @override
  State<PlaylistAlarmsPage> createState() => _PlaylistAlarmsPageState();
}

class _PlaylistAlarmsPageState extends State<PlaylistAlarmsPage>
    with WidgetsBindingObserver {
  final _service = PlaylistAlarmService.instance;
  bool _canScheduleExactly = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermission(sync: true);
    }
  }

  Future<void> _refreshPermission({bool sync = false}) async {
    final allowed = await _service.canScheduleExactAlarms();
    if (!mounted) return;
    setState(() => _canScheduleExactly = allowed);
    if (sync && allowed) await _service.syncNativeSchedule();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n!.playlistAlarms)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addAlarm,
        icon: const Icon(FluentIcons.add_24_regular),
        label: Text(context.l10n!.addAlarm),
      ),
      body: ValueListenableBuilder<List<PlaylistAlarm>>(
        valueListenable: _service.alarms,
        builder: (context, alarms, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 112),
            children: [
              if (!_canScheduleExactly) _buildPermissionCard(),
              if (alarms.isEmpty)
                _buildEmptyState()
              else
                ...alarms.map(_buildAlarmCard),
              const MiniPlayerBottomSpace(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPermissionCard() {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.errorContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n!.alarmPermissionRequired,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.onErrorContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              context.l10n!.alarmPermissionDescription,
              style: TextStyle(color: colors.onErrorContainer),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _service.requestExactAlarmPermission,
              child: Text(context.l10n!.allowAlarms),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 24),
      child: Column(
        children: [
          Icon(
            FluentIcons.clock_alarm_48_regular,
            size: 72,
            color: colors.primary,
          ),
          const SizedBox(height: 18),
          Text(
            context.l10n!.noPlaylistAlarms,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n!.playlistAlarmDescription,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildAlarmCard(PlaylistAlarm alarm) {
    final time = MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay(hour: alarm.hour, minute: alarm.minute));
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _editAlarm(alarm),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        time,
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: alarm.enabled
                                  ? null
                                  : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        alarm.playlistTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _repeatLabel(alarm.weekdays),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Switch(
              value: alarm.enabled,
              onChanged: (value) => _toggle(alarm, value),
            ),
            PopupMenuButton<String>(
              onSelected: (action) {
                if (action == 'edit') _editAlarm(alarm);
                if (action == 'delete') _deleteAlarm(alarm);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    leading: const Icon(FluentIcons.edit_24_regular),
                    title: Text(context.l10n!.edit),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: const Icon(FluentIcons.delete_24_regular),
                    title: Text(context.l10n!.delete),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addAlarm() async {
    if (!await _ensurePermission()) return;
    final alarm = await _showEditor();
    if (alarm != null) await _service.save(alarm);
  }

  Future<void> _editAlarm(PlaylistAlarm alarm) async {
    final updated = await _showEditor(existing: alarm);
    if (updated != null) await _service.save(updated);
  }

  Future<void> _toggle(PlaylistAlarm alarm, bool enabled) async {
    if (enabled && !await _ensurePermission()) return;
    await _service.setEnabled(alarm, enabled);
  }

  Future<bool> _ensurePermission() async {
    if (await _service.canScheduleExactAlarms()) return true;
    if (!mounted) return false;
    final shouldOpen = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n!.alarmPermissionRequired),
        content: Text(context.l10n!.alarmPermissionDescription),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n!.allowAlarms),
          ),
        ],
      ),
    );
    if (shouldOpen == true) await _service.requestExactAlarmPermission();
    return false;
  }

  Future<PlaylistAlarm?> _showEditor({PlaylistAlarm? existing}) async {
    final playlists = await _service.availablePlaylists();
    if (!mounted) return null;
    if (playlists.isEmpty) {
      showToast(context, context.l10n!.noPlaylistsForAlarm);
      return null;
    }

    var selectedTime = TimeOfDay(
      hour: existing?.hour ?? TimeOfDay.now().hour,
      minute: existing?.minute ?? TimeOfDay.now().minute,
    );
    var selectedPlaylistId = existing?.playlistId;
    final selectedDays = Set<int>.from(existing?.weekdays ?? const <int>{});
    if (selectedPlaylistId != null &&
        !playlists.any(
          (playlist) => playlist['ytid']?.toString() == selectedPlaylistId,
        )) {
      playlists.add({
        'ytid': selectedPlaylistId,
        'title': existing?.playlistTitle ?? selectedPlaylistId,
      });
    }
    selectedPlaylistId ??= playlists.first['ytid']?.toString();

    return showDialog<PlaylistAlarm>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selectedPlaylist = playlists.firstWhere(
            (playlist) => playlist['ytid']?.toString() == selectedPlaylistId,
          );
          return AlertDialog(
            title: Text(
              existing == null
                  ? context.l10n!.addAlarm
                  : context.l10n!.editAlarm,
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: selectedTime,
                      );
                      if (picked != null) {
                        setDialogState(() => selectedTime = picked);
                      }
                    },
                    icon: const Icon(FluentIcons.clock_24_regular),
                    label: Text(
                      MaterialLocalizations.of(context)
                          .formatTimeOfDay(selectedTime),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: selectedPlaylistId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: context.l10n!.alarmPlaylist,
                      border: const OutlineInputBorder(),
                    ),
                    items: playlists
                        .map(
                          (playlist) => DropdownMenuItem<String>(
                            value: playlist['ytid']?.toString(),
                            child: Text(
                              playlist['title']?.toString() ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setDialogState(() => selectedPlaylistId = value),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    context.l10n!.repeat,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: List.generate(7, (index) {
                      final day = index + 1;
                      return FilterChip(
                        label: Text(_weekdayLabel(day)),
                        selected: selectedDays.contains(day),
                        onSelected: (selected) {
                          setDialogState(() {
                            if (selected) {
                              selectedDays.add(day);
                            } else {
                              selectedDays.remove(day);
                            }
                          });
                        },
                      );
                    }),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    selectedDays.isEmpty
                        ? context.l10n!.alarmOnceHint
                        : _repeatLabel(selectedDays),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.l10n!.cancel),
              ),
              FilledButton(
                onPressed: selectedPlaylistId == null
                    ? null
                    : () {
                        Navigator.pop(
                          dialogContext,
                          PlaylistAlarm(
                            id:
                                existing?.id ??
                                'alarm-${DateTime.now().microsecondsSinceEpoch}',
                            hour: selectedTime.hour,
                            minute: selectedTime.minute,
                            playlistId: selectedPlaylistId!,
                            playlistTitle:
                                selectedPlaylist['title']?.toString() ?? '',
                            enabled: existing?.enabled ?? true,
                            weekdays: selectedDays,
                          ),
                        );
                      },
                child: Text(context.l10n!.save),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _deleteAlarm(PlaylistAlarm alarm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n!.deleteAlarm),
        content: Text(context.l10n!.deleteAlarmQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n!.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) await _service.remove(alarm.id);
  }

  String _repeatLabel(Set<int> days) {
    if (days.isEmpty) return context.l10n!.alarmOnce;
    if (days.length == 7) return context.l10n!.everyDay;
    if (days.containsAll(const {1, 2, 3, 4, 5}) && days.length == 5) {
      return context.l10n!.weekdays;
    }
    if (days.containsAll(const {6, 7}) && days.length == 2) {
      return context.l10n!.weekends;
    }
    final sortedDays = days.toList()..sort();
    return sortedDays.map(_weekdayLabel).join(', ');
  }

  String _weekdayLabel(int day) => switch (day) {
    DateTime.monday => context.l10n!.mondayShort,
    DateTime.tuesday => context.l10n!.tuesdayShort,
    DateTime.wednesday => context.l10n!.wednesdayShort,
    DateTime.thursday => context.l10n!.thursdayShort,
    DateTime.friday => context.l10n!.fridayShort,
    DateTime.saturday => context.l10n!.saturdayShort,
    _ => context.l10n!.sundayShort,
  };
}
