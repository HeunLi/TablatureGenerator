import 'dart:math' as math;

double _seconds(Duration duration) =>
    duration.inMicroseconds / Duration.microsecondsPerSecond;

Duration _durationOf(double seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

/// One tempo/meter change on the timeline.
///
/// **A marker's [time] is a downbeat** — a bar line. That single rule is
/// what makes the whole model predictable: a tempo change can't land
/// halfway through a measure, so there's never a question of how to number
/// or draw a measure that straddles two tempos. It also means the *first*
/// marker's time is the song's first downbeat, which doubles as the grid
/// offset: real recordings almost never start on beat 1 at exactly 0:00,
/// and without this the entire grid is uniformly wrong no matter how
/// accurate the BPM is.
class TempoMarker {
  const TempoMarker({
    required this.time,
    required this.bpm,
    this.beatsPerMeasure = 4,
  });

  /// Absolute position on the audio timeline where this tempo/meter takes
  /// effect, and — see the class doc — a bar line.
  final Duration time;

  final double bpm;

  /// Time signature numerator (e.g. 4 for 4/4, 3 for 3/4). Per-marker
  /// rather than per-project so a song can change meter for a bridge
  /// without needing a second project.
  final int beatsPerMeasure;

  double get secondsPerBeat => 60 / bpm;
  double get secondsPerMeasure => beatsPerMeasure * secondsPerBeat;

  TempoMarker copyWith({Duration? time, double? bpm, int? beatsPerMeasure}) =>
      TempoMarker(
        time: time ?? this.time,
        bpm: bpm ?? this.bpm,
        beatsPerMeasure: beatsPerMeasure ?? this.beatsPerMeasure,
      );

  Map<String, dynamic> toJson() => {
        'timeMs': time.inMilliseconds,
        'bpm': bpm,
        'beatsPerMeasure': beatsPerMeasure,
      };

  factory TempoMarker.fromJson(Map<String, dynamic> json) => TempoMarker(
        time: Duration(milliseconds: (json['timeMs'] as num).toInt()),
        bpm: (json['bpm'] as num).toDouble(),
        beatsPerMeasure: (json['beatsPerMeasure'] as num?)?.toInt() ?? 4,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TempoMarker &&
          other.time == time &&
          other.bpm == bpm &&
          other.beatsPerMeasure == beatsPerMeasure;

  @override
  int get hashCode => Object.hash(time, bpm, beatsPerMeasure);
}

/// The project's tempo track: an ordered, always non-empty list of
/// [TempoMarker]s, plus all the beat<->time math that used to be a single
/// `bpm` number scattered across the painter, the gesture handlers and the
/// export renderer.
///
/// **Positions stay linear in time, not in beats.** The x axis of the
/// editor remains `seconds * pixelsPerSecond`, so the waveform is never
/// warped and a note's stored `Duration` still means exactly what it says;
/// what the tempo map changes is *where the grid lines fall* on that axis.
/// A slow section therefore shows wider beats, which is the same thing a
/// DAW's bar ruler does over a linear-time waveform. (The alternative —
/// uniform beat widths — would require stretching the audio display to
/// match, which is the wrong trade for a tool whose whole job is lining
/// notes up against what you can see in the waveform.)
///
/// Everything is computed per-segment (marker to next marker) rather than
/// against a single global beat axis. Since every marker starts a new
/// measure, a segment's grid is just a uniform grid anchored at that
/// marker, and only the measure *numbering* has to accumulate across
/// segments.
class TempoMap {
  TempoMap._(this.markers, this._measureAtMarker);

  /// Normalizes [markers] into sorted, de-duplicated order and precomputes
  /// each segment's starting measure number. Never produces an empty map —
  /// callers can always assume `markers.first` exists.
  factory TempoMap(List<TempoMarker> markers) {
    final sorted = [...markers]..sort((a, b) => a.time.compareTo(b.time));
    final normalized = <TempoMarker>[];
    for (final marker in sorted) {
      // Two markers at the same instant is a contradiction, not a pair of
      // segments — the later edit wins.
      if (normalized.isNotEmpty && normalized.last.time == marker.time) {
        normalized[normalized.length - 1] = marker;
      } else {
        normalized.add(marker);
      }
    }
    if (normalized.isEmpty) normalized.add(defaultMarker);

    final measureAtMarker = List<int>.filled(normalized.length, 1);
    for (var i = 1; i < normalized.length; i++) {
      final previous = normalized[i - 1];
      final segmentBeats =
          (_seconds(normalized[i].time) - _seconds(previous.time)) /
              previous.secondsPerBeat;
      // A marker cuts its segment's final measure short, but that partial
      // measure still counts — the next segment starts the measure *after*
      // it, not on top of it.
      final segmentMeasures =
          (segmentBeats / previous.beatsPerMeasure).ceil();
      measureAtMarker[i] = measureAtMarker[i - 1] + math.max(segmentMeasures, 1);
    }

    return TempoMap._(
      List.unmodifiable(normalized),
      List.unmodifiable(measureAtMarker),
    );
  }

  factory TempoMap.single({double bpm = 100, int beatsPerMeasure = 4}) =>
      TempoMap([
        TempoMarker(
          time: Duration.zero,
          bpm: bpm,
          beatsPerMeasure: beatsPerMeasure,
        ),
      ]);

  static const defaultMarker =
      TempoMarker(time: Duration.zero, bpm: 100, beatsPerMeasure: 4);

  static const minBpm = 20.0;
  static const maxBpm = 400.0;
  static const minBeatsPerMeasure = 1;
  static const maxBeatsPerMeasure = 16;

  final List<TempoMarker> markers;

  /// 1-based measure number in effect at each marker's own time. Measure 1
  /// begins at `markers.first.time`.
  final List<int> _measureAtMarker;

  TempoMarker get first => markers.first;

  /// Index of the marker governing [time]. Times before the first marker
  /// (the pick-up/intro region) resolve to marker 0, whose grid simply
  /// extends backwards — otherwise a pick-up bar would have no grid to snap
  /// to at all.
  int indexAt(Duration time) => _indexAtSeconds(_seconds(time));

  int _indexAtSeconds(double seconds) {
    var low = 0;
    var high = markers.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_seconds(markers[mid].time) <= seconds) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }

  TempoMarker markerAt(Duration time) => markers[indexAt(time)];

  double bpmAt(Duration time) => markerAt(time).bpm;

  int beatsPerMeasureAt(Duration time) => markerAt(time).beatsPerMeasure;

  /// End of the segment starting at [index], or `null` for the last one.
  double? _segmentEndSeconds(int index) => index + 1 < markers.length
      ? _seconds(markers[index + 1].time)
      : null;

  /// Snaps [time] onto the nearest grid subdivision of whichever segment it
  /// falls in.
  Duration snap(Duration time, {int subdivisionsPerBeat = 4}) {
    final index = indexAt(time);
    final marker = markers[index];
    final origin = _seconds(marker.time);
    final step = marker.secondsPerBeat / subdivisionsPerBeat;
    var snapped =
        origin + ((_seconds(time) - origin) / step).roundToDouble() * step;

    // A snap can never cross into the next segment: that segment's grid is
    // anchored somewhere else entirely, and its first line — the next
    // marker's own downbeat — is the nearest valid position in that
    // direction.
    final segmentEnd = _segmentEndSeconds(index);
    if (segmentEnd != null && snapped > segmentEnd) snapped = segmentEnd;
    if (snapped < 0) snapped = 0;
    return _durationOf(snapped);
  }

  /// Start/end (seconds) of a block of [beatsPerBlock] consecutive beats
  /// containing [time] — the editor's amber highlight block and the export
  /// renderer's, so both always agree on where a block falls. Blocks are
  /// measured in beats and are deliberately independent of the meter: a 3/4
  /// passage might still want exactly 4 beats lit.
  (double start, double end) beatBlockBounds(Duration time, int beatsPerBlock) {
    if (beatsPerBlock <= 0) return (0, 0);
    final index = indexAt(time);
    final marker = markers[index];
    final origin = _seconds(marker.time);
    final blockSeconds = beatsPerBlock * marker.secondsPerBeat;
    final block = ((_seconds(time) - origin) / blockSeconds).floorToDouble();

    var start = origin + block * blockSeconds;
    var end = start + blockSeconds;
    final segmentEnd = _segmentEndSeconds(index);
    if (segmentEnd != null && end > segmentEnd) end = segmentEnd;
    if (start < 0) start = 0;
    return (start, end < start ? start : end);
  }

  /// Walks every grid line between [fromSeconds] and [toSeconds] in order.
  ///
  /// A callback rather than a returned list because this runs inside
  /// `CustomPainter.paint` on every scrolled frame — materializing a few
  /// hundred records per frame would hand the garbage collector work the
  /// timeline rendering specifically goes out of its way to avoid.
  ///
  /// [measureNumber] is non-null only on measure lines that fall at or
  /// after measure 1; pick-up lines drawn before the first marker are
  /// deliberately unnumbered rather than given zero/negative numbers.
  void visitGridLines(
    double fromSeconds,
    double toSeconds, {
    int subdivisionsPerBeat = 4,
    required void Function(
      double seconds,
      bool isBeat,
      bool isMeasure,
      int? measureNumber,
    ) visit,
  }) {
    if (toSeconds < fromSeconds || subdivisionsPerBeat < 1) return;
    final startIndex = _indexAtSeconds(fromSeconds);

    for (var i = startIndex; i < markers.length; i++) {
      final marker = markers[i];
      final origin = _seconds(marker.time);
      if (i > startIndex && origin > toSeconds) break;

      final segmentEnd = _segmentEndSeconds(i);
      final step = marker.secondsPerBeat / subdivisionsPerBeat;
      if (step <= 0) continue;

      // Segment 0 is allowed to run backwards past its own origin so the
      // pick-up region still has a grid; every later segment starts hard at
      // its marker.
      final lower = i == 0
          ? fromSeconds
          : math.max(fromSeconds, origin);
      final upper =
          segmentEnd == null ? toSeconds : math.min(toSeconds, segmentEnd);
      if (upper < lower) continue;

      final firstLine = ((lower - origin) / step).ceil();
      final lastLine = ((upper - origin) / step).floor();

      for (var line = firstLine; line <= lastLine; line++) {
        final seconds = origin + line * step;
        // The line exactly on the next marker belongs to that marker's
        // segment, which will draw it as its own downbeat.
        if (segmentEnd != null && seconds >= segmentEnd - 1e-9) break;

        // Dart's `%` takes the sign of the divisor, so these stay correct
        // for the negative line indices of a pick-up bar.
        final isBeat = line % subdivisionsPerBeat == 0;
        if (!isBeat) {
          visit(seconds, false, false, null);
          continue;
        }
        final beat = line ~/ subdivisionsPerBeat;
        final isMeasure = beat % marker.beatsPerMeasure == 0;
        int? measureNumber;
        if (isMeasure) {
          final number =
              _measureAtMarker[i] + (beat ~/ marker.beatsPerMeasure);
          if (number >= 1) measureNumber = number;
        }
        visit(seconds, true, isMeasure, measureNumber);
      }
    }
  }

  /// Walks every *beat* (not subdivision) in the range — what the metronome
  /// schedules against. [isDownbeat] marks the first beat of a measure, for
  /// the accented click.
  void visitBeats(
    double fromSeconds,
    double toSeconds, {
    required void Function(double seconds, bool isDownbeat) visit,
  }) {
    visitGridLines(
      fromSeconds,
      toSeconds,
      subdivisionsPerBeat: 1,
      visit: (seconds, isBeat, isMeasure, _) {
        if (isBeat) visit(seconds, isMeasure);
      },
    );
  }

  /// 1-based measure number containing [time]. Can return values below 1 in
  /// the pick-up region before the first marker.
  int measureNumberAt(Duration time) {
    final index = indexAt(time);
    final marker = markers[index];
    final offset =
        ((_seconds(time) - _seconds(marker.time)) / marker.secondsPerMeasure)
            .floor();
    return _measureAtMarker[index] + offset;
  }

  /// Where 1-based [measureNumber] begins. Used by the export renderer to
  /// paginate by measures rather than by a fixed slice of time, which no
  /// longer exists once tempo can change.
  Duration measureStart(int measureNumber) {
    if (measureNumber <= 1) return markers.first.time;
    var index = 0;
    for (var i = 0; i < markers.length; i++) {
      if (_measureAtMarker[i] <= measureNumber) {
        index = i;
      } else {
        break;
      }
    }
    final marker = markers[index];
    var seconds = _seconds(marker.time) +
        (measureNumber - _measureAtMarker[index]) * marker.secondsPerMeasure;
    final segmentEnd = _segmentEndSeconds(index);
    if (segmentEnd != null && seconds > segmentEnd) seconds = segmentEnd;
    return _durationOf(seconds);
  }

  // --- Editing ---

  /// Inserts [marker], replacing any existing marker at the same instant.
  TempoMap withMarker(TempoMarker marker) => TempoMap([
        for (final existing in markers)
          if (existing.time != marker.time) existing,
        marker,
      ]);

  TempoMap replaceAt(int index, TempoMarker marker) => TempoMap([
        for (var i = 0; i < markers.length; i++)
          if (i == index) marker else markers[i],
      ]);

  /// Removes the marker at [index]. The first marker is never removable —
  /// something has to define where beat 1 is.
  TempoMap removeAt(int index) {
    if (index <= 0 || markers.length <= 1) return this;
    return TempoMap([
      for (var i = 0; i < markers.length; i++)
        if (i != index) markers[i],
    ]);
  }

  /// Adjusts the tempo of whichever marker governs [time] — what the
  /// toolbar's BPM stepper edits, so tuning the tempo always affects the
  /// section you're actually listening to rather than the whole song.
  TempoMap adjustBpmAt(Duration time, double delta) {
    final index = indexAt(time);
    final marker = markers[index];
    return replaceAt(
      index,
      marker.copyWith(bpm: (marker.bpm + delta).clamp(minBpm, maxBpm)),
    );
  }

  TempoMap setBpmAt(Duration time, double bpm) {
    final index = indexAt(time);
    return replaceAt(
      index,
      markers[index].copyWith(bpm: bpm.clamp(minBpm, maxBpm)),
    );
  }

  TempoMap adjustBeatsPerMeasureAt(Duration time, int delta) {
    final index = indexAt(time);
    final marker = markers[index];
    return replaceAt(
      index,
      marker.copyWith(
        beatsPerMeasure: (marker.beatsPerMeasure + delta)
            .clamp(minBeatsPerMeasure, maxBeatsPerMeasure),
      ),
    );
  }

  // --- Serialization ---

  Map<String, dynamic> toJson() => {
        'markers': [for (final marker in markers) marker.toJson()],
      };

  factory TempoMap.fromJson(Map<String, dynamic> json) => TempoMap([
        for (final raw in json['markers'] as List)
          TempoMarker.fromJson(raw as Map<String, dynamic>),
      ]);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TempoMap || other.markers.length != markers.length) {
      return false;
    }
    for (var i = 0; i < markers.length; i++) {
      if (markers[i] != other.markers[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(markers);
}
