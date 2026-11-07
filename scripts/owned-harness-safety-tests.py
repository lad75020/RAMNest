#!/usr/bin/env python3
"""Deterministic no-process/no-mount safety tests for the host harness."""
import ast
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SOURCE=Path(__file__).resolve().with_name('run-owned-trash-lifecycle.py')
BASE=Path('/Volumes/WDBlack4TB/.hermes/cache/scratch/ramnest-trash-exclusion-20261107/harness-safety')
BASE.mkdir(parents=True,exist_ok=True)
TREE=ast.parse(SOURCE.read_text())
FUNCTIONS=ast.Module(body=[node for node in TREE.body if isinstance(node,ast.FunctionDef) and node.name in {'read','run','inspect','mounted'}],type_ignores=[])
BOUND=next(node for node in TREE.body if isinstance(node,ast.FunctionDef) and node.name=='bound_session')
PSCALL=next(node.value for node in BOUND.body if isinstance(node,ast.Assign) and any(isinstance(target,ast.Name) and target.id=='command' for target in node.targets))

class FakeProcess:
    instances=[]
    behavior='timeout'
    returncode=0
    def __init__(self,*args,**kwargs):
        self.pid=42424;self.killed=False;self.calls=0;self.kwargs=kwargs;self.args=args[0]
        self.returncode=type(self).returncode;type(self).instances.append(self)
    def __enter__(self):return self
    def __exit__(self,*args):return False
    def communicate(self,input=None,timeout=None):
        self.calls+=1
        if self.calls==1:
            if type(self).behavior=='timeout':raise subprocess.TimeoutExpired(['owned-probe'],timeout)
            if type(self).behavior=='interrupt':raise KeyboardInterrupt()
        return ('{}','')
    def kill(self):self.killed=True
    def wait(self):return self.returncode
    def poll(self):return self.returncode

class HarnessSafety(unittest.TestCase):
    def exercise(self,function,behavior,exit_code=0):
        FakeProcess.instances=[];FakeProcess.behavior=behavior;FakeProcess.returncode=exit_code
        with tempfile.TemporaryDirectory(dir=BASE) as temporary:
            root=Path(temporary);(root/'owner.json').write_text(json.dumps({'uuid':'owned-test'}))
            result={};saves=[]
            context={'subprocess':subprocess,'json':json,'hashlib':__import__('hashlib'),'Path':Path,
                     'root':root,'source':root/'source','store':root/'store','ref':'owned-id',
                     'readback':root/'owned-readback','cli':root/'owned-cli','frozen':{},'token':'owned-test',
                     'commands':[],'result':result,'pid':42424,'save':lambda:saves.append(dict(result))}
            exec(compile(FUNCTIONS,str(SOURCE),'exec'),context)
            context['inspect_ps']=lambda:eval(compile(ast.Expression(body=PSCALL),str(SOURCE),'eval'),context)
            caught=None
            with patch.object(subprocess,'Popen',FakeProcess):
                try:context[function](*(['info','owned-id','--json'] if function=='run' else []))
                except BaseException as error:caught=error
            self.assertEqual(len(FakeProcess.instances),1)
            child=FakeProcess.instances[0]
            if behavior in {'timeout','interrupt'}:
                self.assertFalse(child.killed,'Harness killed its owned child')
                self.assertIsInstance(caught,RuntimeError)
                key='pendingOwnedReadbackPID' if function=='read' else 'pendingOwnedCLIPID' if function=='run' else 'pendingOwnedInspectionPID'
                self.assertEqual(result.get(key),child.pid)
                self.assertTrue(saves,'PID evidence must be persisted before returning')
            elif exit_code:
                self.assertIsNotNone(caught,'Nonzero child exit must fail')
            else:self.assertIsNone(caught)
            self.assertTrue(child.kwargs.get('start_new_session'),'Keep child out of parent interrupt group')
    def test_readback_timeout_retains_child(self):self.exercise('read','timeout')
    def test_readback_interrupt_retains_child(self):self.exercise('read','interrupt')
    def test_readback_success(self):self.exercise('read','success')
    def test_readback_nonzero_fails(self):self.exercise('read','success',3)
    def test_cli_timeout_retains_child(self):self.exercise('run','timeout')
    def test_cli_interrupt_retains_child(self):self.exercise('run','interrupt')
    def test_cli_success(self):self.exercise('run','success')
    def test_cli_nonzero_fails(self):self.exercise('run','success',3)
    def test_mount_inspection_timeout(self):self.exercise('mounted','timeout')
    def test_mount_inspection_interrupt(self):self.exercise('mounted','interrupt')
    def test_mount_inspection_success(self):self.exercise('mounted','success')
    def test_mount_inspection_nonzero(self):self.exercise('mounted','success',3)
    def test_ps_inspection_timeout(self):self.exercise('inspect_ps','timeout')
    def test_ps_inspection_interrupt(self):self.exercise('inspect_ps','interrupt')
    def test_ps_inspection_success(self):self.exercise('inspect_ps','success')
    def test_ps_inspection_nonzero(self):self.exercise('inspect_ps','success',3)

if __name__=='__main__':unittest.main(verbosity=2)
