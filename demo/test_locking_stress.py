#!/usr/bin/env python3
"""Local, non-root invariants for the opt-in stress harness (no VMs launched)."""
import json
from pathlib import Path
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent


def manifest(*args):
    return json.loads(subprocess.check_output([sys.executable, str(HERE / 'locking-stress-vmi.py'), 'test', *args]))


class StressHarnessTests(unittest.TestCase):
    def test_matched_allowance_and_fixed_guest(self):
        for args, lock in [([], 'NotRequired'), (['--locked'], 'Required')]:
            v = manifest(*args)['spec']
            d = v['domain']
            self.assertEqual(d['memory']['guest'], '1Gi')
            self.assertEqual(d['memory']['maxGuest'], '1Gi')
            self.assertEqual(d['resources']['requests'], d['resources']['limits'])
            self.assertEqual(d['resources']['requests']['memory'], '1Gi')
            self.assertEqual(d['memory']['reservedOverhead']['memLock'], lock)
            if lock == 'NotRequired':
                self.assertEqual(d['memory']['reservedOverhead']['addedOverhead'], '1Gi')
            data = v['volumes'][1]['cloudInitNoCloud']['userData']
            self.assertLessEqual(len(data.encode()), 2048)
            cloud = json.loads(data.split('\n', 1)[1])
            unit = cloud['write_files'][1]['content']
            self.assertIn('RuntimeMaxSec=900', unit)
            self.assertIn('Restart=no', unit)
            self.assertNotIn('descheduler.alpha.kubernetes.io/evict', manifest(*args)['metadata']['annotations'])

    def test_tight_cpu_and_legacy_budget(self):
        d = manifest('--cpu', '100m', '--legacy-unlocked-request')['spec']['domain']
        self.assertEqual(d['resources']['limits']['cpu'], '100m')
        self.assertEqual(d['resources']['requests']['memory'], '2Gi')
        self.assertNotIn('reservedOverhead', d['memory'])

    def test_invalid_pressure_budget_does_not_run(self):
        result = subprocess.run([sys.executable, str(HERE / 'locking-stress-pressure.py'), '20000', '150', '45'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'bounds:', result.stderr)

    def test_invalid_client_duration_does_not_run(self):
        result = subprocess.run([sys.executable, str(HERE / 'locking-stress-client.py'), '901', '127.0.0.1'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'duration must be', result.stderr)


if __name__ == '__main__':
    unittest.main()
