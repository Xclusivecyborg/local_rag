import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_rag/document_indexing/chunker.dart';
import 'package:local_rag/vector_search/objectbox_store.dart';

/// A deterministic unit vector pointing mostly along [axis].
List<double> vec(int dims, int axis, {double noise = 0.0}) {
  final rng = math.Random(axis * 7919 + dims);
  final v = List<double>.generate(
      dims, (i) => (i == axis ? 1.0 : 0.0) + rng.nextDouble() * noise);
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = math.sqrt(n);
  return [for (final x in v) x / n];
}

List<Chunk> chunks(List<(String text, String source, int index)> rows) => [
      for (final r in rows) Chunk(text: r.$1, source: r.$2, index: r.$3),
    ];

void main() {
  late Directory tmp;
  final open = <ObjectBoxStore>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('obx_test');
  });

  tearDown(() async {
    for (final s in open) {
      try {
        s.close();
      } on Object {
        // already closed by the test
      }
    }
    open.clear();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<ObjectBoxStore> newStore({
    int dimension = 384,
    String model = 'all-minilm:22m',
    String sub = 'db',
  }) async {
    final s = await ObjectBoxStore.create(
      Directory('${tmp.path}/$sub'),
      embeddingModel: model,
      dimension: dimension,
    );
    open.add(s);
    return s;
  }

  group('which dimensions are supported', () {
    test('every width up to the largest declared index', () {
      expect(ObjectBoxStore.supports(384), isTrue, reason: 'all-MiniLM');
      expect(ObjectBoxStore.supports(1024), isTrue, reason: 'mxbai');
      expect(ObjectBoxStore.supports(768), isTrue, reason: 'nomic and friends');
      expect(ObjectBoxStore.supports(512), isTrue,
          reason: 'no entity for 512, but it pads up to the 768 one');
    });

    test('an odd width is stored padded, and still searches correctly',
        () async {
      final store = await newStore(dimension: 512, model: 'odd', sub: 'odd');
      expect(store.dimension, 512, reason: 'what the model produces');
      expect(store.storageDimension, 768, reason: 'what it is stored as');

      store.addAll(
        chunks([('alpha', 'a.md', 0), ('beta', 'b.md', 0)]),
        [vec(512, 0), vec(512, 1)],
      );
      final hits = store.search(vec(512, 1), k: 1);
      expect(hits.first.chunk.text, 'beta');
      expect(hits.first.chunk.embedding, hasLength(512),
          reason: 'the caller must never see the padding');
    });

    test('a width beyond every index is refused loudly, not silently',
        () async {
      // qwen3-embedding at 2560-d. There is no fallback index any more, so
      // this has to be an error the user can act on.
      expect(ObjectBoxStore.supports(2560), isFalse);
      await expectLater(
        ObjectBoxStore.create(Directory('${tmp.path}/nope'),
            embeddingModel: 'qwen3-embedding', dimension: 2560),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('search', () {
    test('finds the nearest chunk', () async {
      final store = await newStore();
      store.addAll(
        chunks([('alpha', 'a.md', 0), ('beta', 'b.md', 0), ('gamma', 'c.md', 0)]),
        [vec(384, 0), vec(384, 1), vec(384, 2)],
      );

      final hits = store.search(vec(384, 1), k: 1);
      expect(hits, hasLength(1));
      expect(hits.first.chunk.text, 'beta');
      expect(hits.first.chunk.source, 'b.md');
    });

    test('an empty index returns nothing rather than throwing', () async {
      final store = await newStore();
      expect(store.isEmpty, isTrue);
      expect(store.search(vec(384, 0)), isEmpty);
    });

    test('a wrong-size query is refused', () async {
      final store = await newStore();
      store.addAll(chunks([('alpha', 'a.md', 0)]), [vec(384, 0)]);
      expect(() => store.search(vec(1024, 0)), throwsA(isA<StateError>()));
    });

    test('maxPerSource caps a dominant source', () async {
      // The reason this cap exists: a 240-row CSV becomes 43 of 55 chunks and
      // takes every slot in the top k. HNSW returns exactly k, so the store
      // has to over-fetch before filtering or it returns fewer than asked.
      final store = await newStore();
      store.addAll(
        chunks([
          ('csv 0', 'sales.csv', 0),
          ('csv 1', 'sales.csv', 1),
          ('csv 2', 'sales.csv', 2),
          ('csv 3', 'sales.csv', 3),
          ('the answer', 'handbook.md', 0),
        ]),
        [
          vec(384, 0, noise: 0.02),
          vec(384, 0, noise: 0.03),
          vec(384, 0, noise: 0.04),
          vec(384, 0, noise: 0.05),
          vec(384, 0, noise: 0.9),
        ],
      );

      final capped = store.search(vec(384, 0, noise: 0.02), k: 3, maxPerSource: 2);
      expect(capped.length, 3, reason: 'over-fetch must still fill k slots');
      final fromCsv = capped.where((c) => c.chunk.source == 'sales.csv').length;
      expect(fromCsv, lessThanOrEqualTo(2));
      expect(capped.map((c) => c.chunk.source), contains('handbook.md'));
    });
  });

  group('the silent-corruption footgun', () {
    test('a wrong-size vector is rejected on write', () async {
      // ObjectBox itself accepts this without complaint — verified in the
      // Phase 0 spike. The guard lives in ObjectBoxStore, so this test is
      // testing our code, not theirs.
      final store = await newStore();
      expect(
        () => store.addAll(chunks([('x', 'a.md', 0)]), [vec(1024, 0)]),
        throwsA(isA<StateError>()),
      );
    });

    test('a chunk/embedding count mismatch is rejected', () async {
      final store = await newStore();
      expect(
        () => store.addAll(
            chunks([('x', 'a.md', 0), ('y', 'a.md', 1)]), [vec(384, 0)]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('persistence', () {
    test('survives close and reopen, remembering its model', () async {
      final dir = Directory('${tmp.path}/persist');
      final first = await ObjectBoxStore.create(dir,
          embeddingModel: 'mxbai-embed-large:latest', dimension: 1024);
      first.addAll(
        chunks([('alpha', 'a.md', 0), ('beta', 'b.md', 0)]),
        [vec(1024, 0), vec(1024, 1)],
      );
      // No save step: ObjectBox wrote every row to disk as it was put, which
      // is the whole claim this test exists to check.
      first.close();

      final reopened = await ObjectBoxStore.open(dir);
      expect(reopened, isNotNull);
      open.add(reopened!);

      expect(reopened.size, 2);
      expect(reopened.dimension, 1024);
      expect(reopened.embeddingModel, 'mxbai-embed-large:latest');
      expect(reopened.isCompatibleWith('mxbai-embed-large:latest'), isTrue);
      expect(reopened.isCompatibleWith('all-minilm:22m'), isFalse);
      expect(reopened.sources, {'a.md', 'b.md'});
      expect(reopened.search(vec(1024, 0), k: 1).first.chunk.text, 'alpha');
    });

    test('source spans survive the round trip', () async {
      // The offsets are only worth persisting if they come back. A retrieved
      // excerpt that cannot be located in its file is just a file name.
      final store = await newStore(sub: 'spans');
      store.addAll(
        [
          const Chunk(
              text: 'alpha', source: 'a.md', index: 0, start: 12, end: 17),
          const Chunk(
              text: 'beta', source: 'b.md', index: 0, start: 340, end: 344),
        ],
        [vec(384, 0), vec(384, 1)],
      );

      final hit = store.search(vec(384, 1), k: 1).first.chunk;
      expect(hit.text, 'beta');
      expect(hit.start, 340);
      expect(hit.end, 344);
    });

    test('an index written before spans existed reads back as zero', () async {
      // Adding a property is a compatible ObjectBox migration: old rows come
      // back with the default rather than failing to load. Worth pinning,
      // because the alternative — a user's saved index refusing to open after
      // an update — is the kind of thing you find out about from a user.
      final store = await newStore(sub: 'nospans');
      store.addAll(
        [const Chunk(text: 'alpha', source: 'a.md', index: 0)],
        [vec(384, 0)],
      );
      final hit = store.search(vec(384, 0), k: 1).first.chunk;
      expect(hit.start, 0);
      expect(hit.end, 0);
    });

    test('opening a directory with no index returns null', () async {
      expect(await ObjectBoxStore.open(Directory('${tmp.path}/missing')), isNull);
    });

    test('create wipes whatever was there before', () async {
      final dir = Directory('${tmp.path}/wipe');
      final first = await ObjectBoxStore.create(dir,
          embeddingModel: 'a', dimension: 384);
      first.addAll(chunks([('old', 'a.md', 0)]), [vec(384, 0)]);
      expect(first.size, 1);
      first.close();

      final second = await ObjectBoxStore.create(dir,
          embeddingModel: 'b', dimension: 384);
      open.add(second);
      expect(second.size, 0, reason: 're-indexing must not append to the old one');
      expect(second.embeddingModel, 'b');
    });
  });

}
