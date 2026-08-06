import 'dart:async';
import 'dart:io';

import 'ollama_client.dart';

/// Starts `ollama serve` detached, returning its pid. Throws if it cannot start.
typedef OllamaSpawn = Future<int?> Function(String executable);

/// Runs a short-lived command (`pgrep`, `kill`) and waits for the result.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// What happened when we tried to stop Ollama.
enum StopOutcome {
  /// It is no longer answering on 11434.
  stopped,

  /// It was not running to begin with.
  notRunning,

  /// Something is serving but we could not identify a process to signal —
  /// most likely Ollama is running inside a container or under another user.
  notFound,

  /// We signalled it, including SIGKILL, and it is still answering.
  failed,
}

/// What happened when we tried to make sure Ollama was up.
enum LaunchOutcome {
  /// It was already serving. Nothing was started.
  alreadyRunning,

  /// We ran `ollama serve` and it started answering within the timeout.
  started,

  /// No `ollama` binary anywhere we know to look.
  notInstalled,

  /// The binary exists but the process would not start.
  launchFailed,

  /// It started but never answered on 11434 — usually the port is taken by
  /// something else, or the model directory is unreadable.
  timedOut,
}

extension LaunchOutcomeX on LaunchOutcome {
  bool get isUp =>
      this == LaunchOutcome.alreadyRunning || this == LaunchOutcome.started;
}

/// Brings Ollama up by running the same command a terminal user would.
///
/// This is plain `Process.start('…/ollama', ['serve'])`, which is only possible
/// because the App Sandbox is off — see macos/Runner/DebugProfile.entitlements.
/// A sandboxed build cannot spawn anything outside its own bundle.
///
/// The process is started fully detached, so Ollama outlives this app. Stopping
/// it is therefore an explicit user action ([stop]) and never something that
/// happens on quit — a server you started from your own terminal should not
/// disappear because a GUI app closed.
///
/// "Fully" is load-bearing. [ProcessStartMode.detachedWithStdio] looks like the
/// better option — same detachment, plus stderr for diagnostics — but the
/// child's stdio stays wired to pipes this process owns. Quit the app and those
/// pipes close; Ollama dies on its next write. Measured: it survived ~3 seconds
/// and then vanished. [ProcessStartMode.detached] sends stdio to /dev/null and
/// genuinely survives, at the cost of never seeing the child's output.
class OllamaLauncher {
  OllamaLauncher(
    this._client, {
    this.startupTimeout = const Duration(seconds: 30),
    this.shutdownTimeout = const Duration(seconds: 8),
    this.pollInterval = const Duration(milliseconds: 400),
    List<String>? searchPaths,
    OllamaSpawn? spawn,
    ProcessRunner? run,
  })  : _searchPaths = searchPaths ?? defaultSearchPaths(),
        _spawn = spawn ?? _startDetached,
        _run = run ?? Process.run;

  final OllamaClient _client;
  final List<String> _searchPaths;
  final OllamaSpawn _spawn;
  final ProcessRunner _run;

  /// Generous: a cold `ollama serve` has to load its model index first.
  /// Injectable so tests can hit the timeout path without waiting 30s.
  final Duration startupTimeout;

  /// How long to let a SIGTERM land before escalating to SIGKILL.
  final Duration shutdownTimeout;
  final Duration pollInterval;

  /// pid of the server we started, if we started it. Preferred over searching,
  /// because it is the one process we can be certain about.
  int? _spawnedPid;

  /// Why the last spawn threw, if it did. A detached process gives us no
  /// stderr, so this is only ever the Process.start failure itself — a missing
  /// executable bit, a bad architecture — never the server's own complaints.
  String? _lastSpawnError;

  /// Absolute path of the binary we found, once [resolve] has run.
  String? resolvedPath;

  /// Where to look for the `ollama` binary.
  ///
  /// A GUI app does NOT inherit your shell's PATH — it gets a minimal
  /// `/usr/bin:/bin:/usr/sbin:/sbin`. So `which ollama` succeeding in Terminal
  /// tells you nothing about whether this process can find it, and searching
  /// PATH would miss every install location that matters. Hence explicit paths.
  static List<String> defaultSearchPaths() {
    final home = Platform.environment['HOME'] ?? '';
    return <String>[
      '/usr/local/bin/ollama', // ollama.com installer
      '/opt/homebrew/bin/ollama', // Homebrew, Apple silicon
      '/usr/local/opt/ollama/bin/ollama', // Homebrew, Intel
      if (home.isNotEmpty) '$home/.local/bin/ollama',
      '/usr/bin/ollama',
      // Last resort: inside the desktop app, which is what the installer's
      // /usr/local/bin symlink points at anyway.
      '/Applications/Ollama.app/Contents/Resources/ollama',
    ];
  }

  /// First existing candidate, or null. Follows symlinks, so the installer's
  /// symlink left dangling by a deleted Ollama.app is correctly skipped.
  String? resolve() {
    for (final path in _searchPaths) {
      if (File(path).existsSync()) return resolvedPath = path;
    }
    return resolvedPath = null;
  }

  Future<String?> probe() => _client.version();

  /// Ensures the server is answering, running `ollama serve` if it is not.
  ///
  /// [onStatus] receives short progress text, because a silent 30-second wait
  /// is indistinguishable from a hang.
  Future<LaunchOutcome> ensureRunning({
    void Function(String message)? onStatus,
  }) async {
    if (await probe() != null) return LaunchOutcome.alreadyRunning;

    final binary = resolve();
    if (binary == null) return LaunchOutcome.notInstalled;

    _lastSpawnError = null;
    onStatus?.call('Starting ollama serve…');
    try {
      _spawnedPid = await _spawn(binary);
    } on Object catch (e) {
      _lastSpawnError = '$e';
      return LaunchOutcome.launchFailed;
    }

    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if (await probe() != null) return LaunchOutcome.started;

      final left = deadline.difference(DateTime.now()).inSeconds;
      if (left > 0) onStatus?.call('Waiting for Ollama… ${left}s');
    }
    return LaunchOutcome.timedOut;
  }

  /// Stops the running Ollama server.
  ///
  /// Ollama exposes no shutdown endpoint, so this is a signal — the same thing
  /// `pkill ollama` does from a terminal. SIGTERM first so it can close its
  /// model files cleanly; SIGKILL only if it ignores that.
  ///
  /// Note that stopping `ollama serve` also takes down the `llama-server`
  /// children it spawned per loaded model. They are its children, not ours.
  Future<StopOutcome> stop({void Function(String message)? onStatus}) async {
    if (await probe() == null) {
      _spawnedPid = null;
      return StopOutcome.notRunning;
    }

    final pids = await _serverPids();
    if (pids.isEmpty) return StopOutcome.notFound;

    onStatus?.call('Stopping Ollama…');
    await _signal(pids, 'TERM');
    if (await _waitUntilDown()) {
      _spawnedPid = null;
      return StopOutcome.stopped;
    }

    onStatus?.call('Not responding — forcing…');
    await _signal(pids, 'KILL');
    if (await _waitUntilDown()) {
      _spawnedPid = null;
      return StopOutcome.stopped;
    }
    return StopOutcome.failed;
  }

  /// Processes serving Ollama: the one we started, plus anything else that
  /// looks like `ollama serve` — the user may well have started it themselves,
  /// and a Stop button that only stops *our* copy would be a lie.
  Future<List<int>> _serverPids() async {
    final pids = <int>{?_spawnedPid};
    try {
      final result = await _run('/usr/bin/pgrep', <String>['-f', 'ollama serve']);
      for (final line in '${result.stdout}'.split('\n')) {
        final found = int.tryParse(line.trim());
        // Never signal ourselves, however unlikely the match.
        if (found != null && found != pid) pids.add(found);
      }
    } on Object {
      // No pgrep, or it failed. _spawnedPid may still be enough.
    }
    return pids.toList();
  }

  Future<void> _signal(List<int> pids, String signal) async {
    for (final target in pids) {
      try {
        await _run('/bin/kill', <String>['-$signal', '$target']);
      } on Object {
        // Already gone, or not ours to signal. The probe below is the verdict.
      }
    }
  }

  /// The only trustworthy check is the port going quiet. A dead pid does not
  /// prove the service stopped — something else may be bound to 11434.
  Future<bool> _waitUntilDown() async {
    final deadline = DateTime.now().add(shutdownTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if (await probe() == null) return true;
    }
    return false;
  }

  String explainStop(StopOutcome outcome) => switch (outcome) {
        StopOutcome.stopped || StopOutcome.notRunning => '',
        StopOutcome.notFound =>
          'Something is answering on port 11434, but no "ollama serve" process '
              'was found to stop. It may be running under another user or in a '
              'container.',
        StopOutcome.failed =>
          'Ollama did not stop, even after SIGKILL. Try "pkill -9 ollama" in a '
              'terminal.',
      };

  /// What to tell the user when [ensureRunning] did not get us up.
  ///
  /// Every failure message ends with the same escape hatch: run it yourself in
  /// a terminal. Detached means we cannot show the server's own error, so the
  /// honest move is to point at the place that can.
  String explain(LaunchOutcome outcome) {
    final detail = _lastSpawnError == null ? '' : '\n\n$_lastSpawnError';
    return switch (outcome) {
      LaunchOutcome.alreadyRunning || LaunchOutcome.started => '',
      LaunchOutcome.notInstalled => 'No "ollama" binary found.\n'
          'Install it from ollama.com or with: brew install ollama\n'
          'Then press Connect.',
      LaunchOutcome.launchFailed => 'Found $resolvedPath but it would not '
          'start.\nRun "ollama serve" in a terminal, then press Connect.$detail',
      LaunchOutcome.timedOut =>
        'Started $resolvedPath but nothing answered on port 11434 within '
            '${startupTimeout.inSeconds}s.\n'
            'Run "ollama serve" in a terminal to see what it says.',
    };
  }

  static Future<int?> _startDetached(String executable) async {
    final process = await Process.start(
      executable,
      const <String>['serve'],
      mode: ProcessStartMode.detached,
    );
    return process.pid;
  }
}
