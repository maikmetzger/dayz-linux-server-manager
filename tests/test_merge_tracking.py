
import unittest
import os
import json
import shutil
import tempfile
import sys
import xml.etree.ElementTree as ET
from unittest.mock import patch, MagicMock

# Add lib to path
sys.path.append(os.path.join(os.path.dirname(__file__), '../lib'))
import merge_tracking

class TestMergeTracking(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.instance_dir = os.path.join(self.test_dir, 'instance')
        os.makedirs(os.path.join(self.instance_dir, 'data/state/ce_merge_tracking'), exist_ok=True)
        
    def tearDown(self):
        shutil.rmtree(self.test_dir)
        
    def test_get_tracking_path(self):
        path = merge_tracking.get_tracking_path(self.instance_dir, 'db/cfgrandompresets.xml')
        expected = os.path.join(self.instance_dir, 'data/state/ce_merge_tracking/cfgrandompresets.json')
        self.assertEqual(path, expected)
        
    def test_load_tracking_new(self):
        data = merge_tracking.load_tracking(self.instance_dir, 'db/new.xml')
        self.assertEqual(data['target_file'], 'db/new.xml')
        self.assertEqual(data['entries'], {})
        
    def test_save_and_load(self):
        target = 'db/presets.xml'
        data = {
            "target_file": target,
            "entries": {"Mod1": [{"name": "P1"}]}
        }
        merge_tracking.save_tracking(self.instance_dir, target, data)
        
        loaded = merge_tracking.load_tracking(self.instance_dir, target)
        self.assertEqual(loaded['entries']['Mod1'][0]['name'], 'P1')
        self.assertIsNotNone(loaded.get('last_updated'))
        
    def test_check_collisions(self):
        # Create dummy target XML
        target_xml = os.path.join(self.test_dir, 'target.xml')
        with open(target_xml, 'w') as f:
            f.write('<randompresets><cargo name="Existing1"/><cargo name="Existing2"/></randompresets>')
            
        # Create dummy source XML
        source_xml = os.path.join(self.test_dir, 'source.xml')
        with open(source_xml, 'w') as f:
            f.write('<randompresets><cargo name="Existing1"/><cargo name="Unique1"/></randompresets>')
            
        collisions = merge_tracking.check_collisions(source_xml, target_xml)
        self.assertEqual(len(collisions), 1)
        self.assertEqual(collisions[0]['name'], 'Existing1')
        
    def test_check_collisions_clean(self):
        target_xml = os.path.join(self.test_dir, 'target.xml')
        with open(target_xml, 'w') as f:
            f.write('<randompresets><cargo name="Existing1"/></randompresets>')
            
        source_xml = os.path.join(self.test_dir, 'source.xml')
        with open(source_xml, 'w') as f:
            f.write('<randompresets><cargo name="Unique1"/></randompresets>')
            
        collisions = merge_tracking.check_collisions(source_xml, target_xml)
        self.assertEqual(len(collisions), 0)

    def test_inject_entries(self):
        target_xml = os.path.join(self.test_dir, 'target_merge.xml')
        # Empty target initially
        
        source_xml = os.path.join(self.test_dir, 'source_merge.xml')
        with open(source_xml, 'w') as f:
            f.write('<randompresets><cargo name="Inject1" chance="1.0" /><cargo name="Inject2"><child/></cargo></randompresets>')
            
        added = merge_tracking.inject_entries(target_xml, source_xml, 'ModA', 'ModA Name')
        
        self.assertEqual(len(added), 2)
        self.assertEqual(added[0]['name'], 'Inject1')
        self.assertEqual(added[1]['name'], 'Inject2')
        
        # Check file content
        tree = ET.parse(target_xml)
        root = tree.getroot()
        self.assertEqual(root.tag, 'randompresets')
        self.assertEqual(len(root), 2)
        
    def test_remove_entries(self):
        target_xml = os.path.join(self.test_dir, 'target_remove.xml')
        with open(target_xml, 'w') as f:
            f.write('<randompresets><cargo name="Keep"/><cargo name="Remove"/></randompresets>')
            
        to_remove = [{'name': 'Remove', 'type': 'cargo'}]
        success = merge_tracking.remove_entries(target_xml, to_remove)
        
        self.assertTrue(success)
        
        tree = ET.parse(target_xml)
        root = tree.getroot()
        self.assertEqual(len(root), 1)
        self.assertEqual(root[0].get('name'), 'Keep')

if __name__ == '__main__':
    unittest.main()
