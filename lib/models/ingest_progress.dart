/// How far indexing has got, for the progress bar.
class IngestProgress {
  const IngestProgress(this.stage, {this.done = 0, this.total = 0});
  final String stage;
  final int done;
  final int total;

  double? get fraction => total == 0 ? null : done / total;
}
