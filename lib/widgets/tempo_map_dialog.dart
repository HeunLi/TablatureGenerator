import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/tempo_map.dart';
import 'glass_panel.dart';

/// Opens the tempo-track editor. Returns the edited [TempoMap], or null if
/// the user cancelled.
Future<TempoMap?> showTempoMapDialog(
  BuildContext context, {
  required TempoMap initial,
  required Duration playhead,
}) {
  return showDialog<TempoMap>(
    context: context,
    builder: (_) => _TempoMapDialog(initial: initial, playhead: playhead),
  );
}

/// Structural editing of the tempo track: add, retime and remove markers.
///
/// Deliberately *not* where routine tempo tuning happens — the toolbar's
/// tempo/meter steppers already edit whichever section the playhead is in,
/// live, while the track plays, which is the loop you actually want when
/// matching a grid to a recording. This dialog is for the things that
/// aren't a nudge: seeing the whole tempo track at once, fixing a marker's
/// position to the millisecond, or deleting one placed by mistake.
class _TempoMapDialog extends StatefulWidget {
  const _TempoMapDialog({required this.initial, required this.playhead});

  final TempoMap initial;
  final Duration playhead;

  @override
  State<_TempoMapDialog> createState() => _TempoMapDialogState();
}

class _TempoMapDialogState extends State<_TempoMapDialog> {
  late final List<_MarkerDraft> _drafts = [
    for (final marker in widget.initial.markers) _MarkerDraft(marker),
  ];

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  void _addAtPlayhead() {
    // Inherits the section it's being carved out of, so the marker starts
    // as a no-op and the only thing left to do is tune it.
    final current = widget.initial.markerAt(widget.playhead);
    setState(() {
      _drafts.add(
        _MarkerDraft(
          TempoMarker(
            time: widget.playhead,
            bpm: current.bpm,
            beatsPerMeasure: current.beatsPerMeasure,
          ),
        ),
      );
    });
  }

  void _remove(int index) {
    setState(() {
      _drafts.removeAt(index).dispose();
    });
  }

  /// Drops rows that no longer parse rather than rejecting the whole edit —
  /// a half-typed number in one field shouldn't discard every other change.
  /// [TempoMap] itself re-sorts and de-duplicates, so rows don't have to be
  /// kept in order while editing.
  void _submit() {
    final markers = <TempoMarker>[];
    for (final draft in _drafts) {
      final marker = draft.toMarker();
      if (marker != null) markers.add(marker);
    }
    Navigator.of(context).pop(
      markers.isEmpty ? widget.initial : TempoMap(markers),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassAlertDialog(
      maxWidth: 580,
      title: const Text('Tempo map'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Each marker starts a new bar. The first one is where beat 1 of '
            'the song falls — set it to the first downbeat you hear, and the '
            'whole grid lines up.',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 14),
          const _HeaderRow(),
          const SizedBox(height: 4),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (var i = 0; i < _drafts.length; i++)
                    _MarkerRow(
                      key: ObjectKey(_drafts[i]),
                      draft: _drafts[i],
                      index: i,
                      // Something has to define where beat 1 is, so the
                      // list can never be emptied.
                      onRemove: _drafts.length > 1 ? () => _remove(i) : null,
                      onUsePlayhead: () => setState(
                        () => _drafts[i].setTime(widget.playhead),
                      ),
                      onMeterChanged: (delta) => setState(
                        () => _drafts[i].adjustBeatsPerMeasure(delta),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addAtPlayhead,
              icon: const Icon(Icons.add, size: 16),
              label: Text(
                'Add marker at playhead '
                '(${_formatSeconds(widget.playhead)})',
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Done')),
      ],
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 11,
      color: Colors.white.withValues(alpha: 0.4),
    );
    return Row(
      children: [
        SizedBox(width: 26, child: Text('#', style: style)),
        SizedBox(width: 108, child: Text('Starts at', style: style)),
        const SizedBox(width: 8),
        SizedBox(width: 84, child: Text('Tempo', style: style)),
        const SizedBox(width: 8),
        SizedBox(width: 108, child: Text('Time sig.', style: style)),
      ],
    );
  }
}

class _MarkerRow extends StatelessWidget {
  const _MarkerRow({
    super.key,
    required this.draft,
    required this.index,
    required this.onRemove,
    required this.onUsePlayhead,
    required this.onMeterChanged,
  });

  final _MarkerDraft draft;
  final int index;
  final VoidCallback? onRemove;
  final VoidCallback onUsePlayhead;
  final ValueChanged<int> onMeterChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
          SizedBox(
            width: 108,
            child: _CompactField(
              controller: draft.timeController,
              suffix: 's',
            ),
          ),
          IconButton(
            iconSize: 15,
            visualDensity: VisualDensity.compact,
            tooltip: 'Move to playhead',
            icon: const Icon(Icons.my_location),
            onPressed: onUsePlayhead,
          ),
          SizedBox(
            width: 84,
            child: _CompactField(
              controller: draft.bpmController,
              suffix: 'BPM',
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 108,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.remove),
                  onPressed: () => onMeterChanged(-1),
                ),
                SizedBox(
                  width: 34,
                  child: Text(
                    '${draft.beatsPerMeasure}/4',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: Colors.white),
                  ),
                ),
                IconButton(
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add),
                  onPressed: () => onMeterChanged(1),
                ),
              ],
            ),
          ),
          const Spacer(),
          IconButton(
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            tooltip: onRemove == null
                ? 'The first marker defines beat 1 and cannot be removed'
                : 'Remove marker',
            icon: Icon(
              Icons.delete_outline,
              color: onRemove == null
                  ? Colors.white.withValues(alpha: 0.2)
                  : Colors.redAccent,
            ),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _CompactField extends StatelessWidget {
  const _CompactField({required this.controller, required this.suffix});

  final TextEditingController controller;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 13, color: Colors.white),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      decoration: InputDecoration(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        suffixText: suffix,
        suffixStyle: TextStyle(
          fontSize: 11,
          color: Colors.white.withValues(alpha: 0.4),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

/// One row's in-progress edit. Holds its own controllers so they can be
/// created and disposed with the row rather than rebuilt (and reset
/// mid-typing) on every parent rebuild.
class _MarkerDraft {
  _MarkerDraft(TempoMarker marker)
      : timeController =
            TextEditingController(text: _formatSeconds(marker.time)),
        bpmController = TextEditingController(text: _formatBpm(marker.bpm)),
        beatsPerMeasure = marker.beatsPerMeasure;

  final TextEditingController timeController;
  final TextEditingController bpmController;
  int beatsPerMeasure;

  void setTime(Duration time) {
    timeController.text = _formatSeconds(time);
  }

  void adjustBeatsPerMeasure(int delta) {
    beatsPerMeasure = (beatsPerMeasure + delta)
        .clamp(TempoMap.minBeatsPerMeasure, TempoMap.maxBeatsPerMeasure);
  }

  /// Null when the row doesn't currently describe a usable marker (a
  /// half-typed or empty field), so [_TempoMapDialogState._submit] can skip
  /// it instead of failing the whole edit.
  TempoMarker? toMarker() {
    final seconds = double.tryParse(timeController.text.trim());
    final bpm = double.tryParse(bpmController.text.trim());
    if (seconds == null || bpm == null || bpm <= 0) return null;
    return TempoMarker(
      time: Duration(
        microseconds:
            ((seconds < 0 ? 0.0 : seconds) * Duration.microsecondsPerSecond)
                .round(),
      ),
      bpm: bpm.clamp(TempoMap.minBpm, TempoMap.maxBpm),
      beatsPerMeasure: beatsPerMeasure,
    );
  }

  void dispose() {
    timeController.dispose();
    bpmController.dispose();
  }
}

String _formatSeconds(Duration time) =>
    (time.inMicroseconds / Duration.microsecondsPerSecond).toStringAsFixed(3);

String _formatBpm(double bpm) =>
    bpm == bpm.roundToDouble() ? bpm.toStringAsFixed(0) : bpm.toStringAsFixed(2);
