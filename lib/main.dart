import 'package:flutter/material.dart';

import 'core/facade/facade.dart';
import 'platform/platform.dart';
import 'ui/app.dart';
import 'ui/state/app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final engine = TingEngine();
  final settingsStore = SettingsStore();
  final audioStore = AudioStore();
  final database = BookDatabase();
  final filePicker = TxtFilePicker();
  final player = AudioPlayerService();
  final appState = AppState(
    engine: engine,
    settingsStore: settingsStore,
    audioStore: audioStore,
    filePicker: filePicker,
    player: player,
    database: database,
  );

  appState.init();

  runApp(TingApp(appState: appState));
}
