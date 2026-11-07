#!/usr/bin/env python3
"""Prevent the known AppGraph feedback paths from returning (not GUI proof)."""
from pathlib import Path
root=Path(__file__).resolve().parent.parent
app=(root/'Sources/RAMNestApp/RAMNestApp.swift').read_text()
model=(root/'Sources/RAMNestApp/AppModel.swift').read_text()
commands=(root/'Sources/RAMNestApp/AppCommands.swift').read_text()
assert '@StateObject' not in app, 'App scene must not observe repository publications'
assert '.onAppear' not in app, 'View appearance must not own application launch'
assert 'MenuBarExtra(' not in app, 'Mode must not insert/remove an observed App scene'
assert 'let model = AppModel()' in app and 'applicationDidFinishLaunching' in app
assert 'DispatchQueue.main.async' in app
assert '.commands { RAMNestCommands(model: delegate.model) }' in app
assert 'let model: AppModel' in commands
assert '@ObservedObject' not in commands and '@EnvironmentObject' not in commands
start=model[model.index('    func start()'):model.index('    func refresh()')]
assert 'guard refreshTask == nil' in start and 'NSApp.' not in start
mode=model[model.index('    func setMenuMode('):model.index('    func quit()')]
assert 'NSApp.' not in mode, 'Model persistence cannot synchronously change scene activation'
print('PASS GUI graph contract: delegate lifetime, deferred/idempotent startup, stable commands, no observed scene insertion or model activation mutation')
