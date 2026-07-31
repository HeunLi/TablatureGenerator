import 'package:bass_tab_studio/models/tab_project.dart';
import 'package:bass_tab_studio/models/tempo_map.dart';
import 'package:flutter_test/flutter_test.dart';

/// `TempoMap` is the load-bearing piece of the timing model — the grid,
/// note snapping, the highlight block, the metronome's beat scheduling and
/// the exporter's pagination all derive from it. It's also pure Dart with
/// no browser dependency, which makes it the one part of this app that can
/// actually be covered here (see docs/DECISIONS.md on why browser-side
/// behaviour can't be).
void main() {
  Duration secs(double value) =>
      Duration(microseconds: (value * Duration.microsecondsPerSecond).round());

  double asSeconds(Duration value) =>
      value.inMicroseconds / Duration.microsecondsPerSecond;

  group('single-marker map', () {
    final map = TempoMap.single(bpm: 120, beatsPerMeasure: 4);

    test('snaps to the nearest sixteenth', () {
      // 120 BPM => 0.5s per beat => 0.125s per sixteenth. 0.6s sits 4.8
      // sixteenths in, so it rounds to the fifth at 0.625s.
      expect(asSeconds(map.snap(secs(0.6))), closeTo(0.625, 1e-9));
      expect(asSeconds(map.snap(secs(0.66))), closeTo(0.625, 1e-9));
      expect(asSeconds(map.snap(secs(0.69))), closeTo(0.75, 1e-9));
    });

    test('never snaps to a negative time', () {
      expect(map.snap(secs(0.01)), Duration.zero);
    });

    test('highlight block covers the beats containing the playhead', () {
      final (start, end) = map.beatBlockBounds(secs(1.1), 4);
      expect(start, closeTo(0, 1e-9));
      expect(end, closeTo(2, 1e-9));

      final (nextStart, nextEnd) = map.beatBlockBounds(secs(2.4), 4);
      expect(nextStart, closeTo(2, 1e-9));
      expect(nextEnd, closeTo(4, 1e-9));
    });

    test('measures are numbered from 1 and spaced by the meter', () {
      expect(map.measureNumberAt(Duration.zero), 1);
      expect(map.measureNumberAt(secs(1.9)), 1);
      expect(map.measureNumberAt(secs(2.0)), 2);
      expect(asSeconds(map.measureStart(3)), closeTo(4, 1e-9));
    });
  });

  group('grid offset (first marker is beat 1)', () {
    // The whole reason the first marker carries a time: a recording whose
    // first downbeat is at 2s used to be un-griddable.
    final map = TempoMap([
      const TempoMarker(time: Duration(seconds: 2), bpm: 120),
    ]);

    test('measure 1 starts at the first marker, not at 0:00', () {
      expect(asSeconds(map.measureStart(1)), closeTo(2, 1e-9));
      expect(map.measureNumberAt(secs(2.5)), 1);
    });

    test('snapping works in the pick-up region before beat 1', () {
      // The grid extends backwards at the first marker's tempo so notes in
      // a pick-up bar still have something to land on.
      expect(asSeconds(map.snap(secs(1.02))), closeTo(1.0, 1e-9));
      expect(asSeconds(map.snap(secs(1.9))), closeTo(1.875, 1e-9));
    });

    test('pick-up bar lines are drawn but left unnumbered', () {
      final numbered = <int>[];
      var lineCount = 0;
      map.visitGridLines(
        0,
        2,
        subdivisionsPerBeat: 1,
        visit: (seconds, isBeat, isMeasure, measureNumber) {
          lineCount++;
          if (measureNumber != null) numbered.add(measureNumber);
        },
      );
      // Beats at 0.0, 0.5, 1.0, 1.5, 2.0 — all present...
      expect(lineCount, 5);
      // ...but only the one at 2.0s is measure 1; the earlier bar line at
      // 0.0s would be "measure 0", which is not a thing worth labelling.
      expect(numbered, [1]);
    });
  });

  group('tempo and meter changes', () {
    // 0–4s at 120 BPM in 4/4 (two measures), then 3/4 at 60 BPM.
    final map = TempoMap([
      const TempoMarker(time: Duration.zero, bpm: 120),
      const TempoMarker(
        time: Duration(seconds: 4),
        bpm: 60,
        beatsPerMeasure: 3,
      ),
    ]);

    test('reports the tempo of the section a time falls in', () {
      expect(map.bpmAt(secs(3.9)), 120);
      expect(map.bpmAt(secs(4.0)), 60);
      expect(map.beatsPerMeasureAt(secs(5)), 3);
    });

    test('measure numbering continues across the change', () {
      // Two 4/4 measures fit in the first segment, so the marker begins
      // measure 3 — and measures after it are 3 seconds long, not 2.
      expect(map.measureNumberAt(secs(4.0)), 3);
      expect(asSeconds(map.measureStart(3)), closeTo(4, 1e-9));
      expect(asSeconds(map.measureStart(4)), closeTo(7, 1e-9));
      expect(map.measureNumberAt(secs(7.5)), 4);
    });

    test('grid lines switch spacing at the marker', () {
      final beats = <double>[];
      map.visitGridLines(
        0,
        7,
        subdivisionsPerBeat: 1,
        visit: (seconds, isBeat, isMeasure, _) => beats.add(seconds),
      );
      // Half-second beats up to the marker, then one-second beats after it,
      // with no duplicated or missing line at the seam.
      expect(
        beats.map((b) => double.parse(b.toStringAsFixed(3))).toList(),
        [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 5, 6, 7],
      );
    });

    test('a snap cannot cross into the next section', () {
      final tight = TempoMap([
        const TempoMarker(time: Duration.zero, bpm: 120),
        const TempoMarker(time: Duration(milliseconds: 1100), bpm: 120),
      ]);
      // 1.08s would round up to 1.125s, which lives past the marker — the
      // marker's own downbeat is the nearest real grid line that way.
      expect(asSeconds(tight.snap(secs(1.08))), closeTo(1.1, 1e-9));
      // Rounding down is unaffected.
      expect(asSeconds(tight.snap(secs(1.04))), closeTo(1.0, 1e-9));
    });

    test('a highlight block is cut short by the next section', () {
      final tight = TempoMap([
        const TempoMarker(time: Duration.zero, bpm: 120),
        const TempoMarker(time: Duration(milliseconds: 1500), bpm: 120),
      ]);
      final (start, end) = tight.beatBlockBounds(secs(0.2), 4);
      expect(start, closeTo(0, 1e-9));
      expect(end, closeTo(1.5, 1e-9));
    });

    test('beats report downbeats for the metronome accent', () {
      final downbeats = <double>[];
      map.visitBeats(
        0,
        7,
        visit: (seconds, isDownbeat) {
          if (isDownbeat) downbeats.add(seconds);
        },
      );
      // 4/4 at 120 BPM: bars at 0s and 2s. Then 3/4 at 60 BPM: bars at 4s
      // and 7s.
      expect(
        downbeats.map((b) => double.parse(b.toStringAsFixed(3))).toList(),
        [0, 2, 4, 7],
      );
    });
  });

  group('normalization and editing', () {
    test('markers are sorted and de-duplicated by time', () {
      final map = TempoMap([
        const TempoMarker(time: Duration(seconds: 4), bpm: 90),
        const TempoMarker(time: Duration.zero, bpm: 120),
        // Same instant as the first: the later entry wins rather than
        // creating a zero-length section.
        const TempoMarker(time: Duration(seconds: 4), bpm: 100),
      ]);
      expect(map.markers.length, 2);
      expect(map.markers.first.time, Duration.zero);
      expect(map.markers[1].bpm, 100);
    });

    test('an empty marker list still yields a usable map', () {
      expect(TempoMap(const []).markers.length, 1);
    });

    test('the first marker cannot be removed', () {
      final map = TempoMap([
        const TempoMarker(time: Duration.zero, bpm: 120),
        const TempoMarker(time: Duration(seconds: 4), bpm: 90),
      ]);
      expect(map.removeAt(0).markers.length, 2);
      expect(map.removeAt(1).markers.length, 1);
    });

    test('bpm edits apply to the section under the given time', () {
      final map = TempoMap([
        const TempoMarker(time: Duration.zero, bpm: 120),
        const TempoMarker(time: Duration(seconds: 4), bpm: 90),
      ]).adjustBpmAt(secs(5), 10);
      expect(map.markers[0].bpm, 120);
      expect(map.markers[1].bpm, 100);
    });

    test('bpm stays inside the supported range', () {
      final map = TempoMap.single(bpm: TempoMap.maxBpm).adjustBpmAt(
        Duration.zero,
        50,
      );
      expect(map.markers.single.bpm, TempoMap.maxBpm);
    });
  });

  group('persistence', () {
    test('round-trips through JSON', () {
      final map = TempoMap([
        const TempoMarker(time: Duration.zero, bpm: 137.5),
        const TempoMarker(
          time: Duration(milliseconds: 4250),
          bpm: 90,
          beatsPerMeasure: 3,
        ),
      ]);
      expect(TempoMap.fromJson(map.toJson()), map);
    });

    test('projects saved before the tempo track migrate losslessly', () {
      // The pre-tempo-map shape: a flat bpm + beatsPerMeasure, which
      // describes exactly a one-marker map anchored at 0:00.
      final project = TabProject.fromJson({
        'id': 'p1',
        'title': 'Legacy',
        'bpm': 138,
        'beatsPerMeasure': 3,
        'audioFileName': null,
        'notes': <dynamic>[],
      });
      expect(project.tempo.markers.length, 1);
      expect(project.tempo.markers.single.time, Duration.zero);
      expect(project.tempo.markers.single.bpm, 138);
      expect(project.tempo.markers.single.beatsPerMeasure, 3);
    });

    test('a project round-trips through JSON with its tempo track', () {
      final project = TabProject(
        id: 'p2',
        title: 'Song',
        notes: const [],
        tempo: TempoMap([
          const TempoMarker(time: Duration(milliseconds: 1200), bpm: 96),
          const TempoMarker(
            time: Duration(seconds: 30),
            bpm: 104,
            beatsPerMeasure: 6,
          ),
        ]),
      );
      expect(TabProject.fromJson(project.toJson()).tempo, project.tempo);
    });
  });
}
