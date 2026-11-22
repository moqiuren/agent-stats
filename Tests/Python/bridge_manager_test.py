import unittest,tempfile,pathlib,json,hashlib,sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
from Scripts.bridge_manager import install,uninstall,BEGIN,ASSET
class BridgeRollbackTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name);self.renderer=self.root/'renderer';(self.renderer/'assets').mkdir(parents=True);self.support=self.root/'support';self.index=self.renderer/'index.html';self.original=b'<!doctype html>\n<body><div id="app"></div>\n</body>\n';self.index.write_bytes(self.original);self.client=self.root/'client.js';self.client.write_text('const config = __AGENT_STATS_BRIDGE_CONFIG__;')
 def tearDown(self):self.temp.cleanup()
 def put(self):install(self.renderer,self.support,self.client)
 def test_exact_roundtrip_and_idempotent_install(self):
  self.put();self.put();self.assertEqual(self.index.read_text().count(BEGIN),1);uninstall(self.support,disable=False);self.assertEqual(self.index.read_bytes(),self.original);self.assertFalse((self.renderer/ASSET).exists())
 def test_preserve_other_edits(self):
  self.put();self.index.write_text(self.index.read_text().replace('<body>','<body data-user-change="yes">'));uninstall(self.support,disable=False);self.assertIn('data-user-change',self.index.read_text());self.assertNotIn(BEGIN,self.index.read_text())
 def test_never_overwrite_new_app_version(self):
  self.put();new=b'<body>new Kimi build</body>';self.index.write_bytes(new);uninstall(self.support,disable=False);self.assertEqual(self.index.read_bytes(),new)
 def test_changed_bridge_stops_before_page_modification(self):
  self.put();before=self.index.read_bytes();(self.renderer/ASSET).write_text('user modification');
  with self.assertRaises(RuntimeError):uninstall(self.support,disable=False)
  self.assertEqual(self.index.read_bytes(),before)
 def test_corrupt_backup_aborts(self):
  self.put();before=self.index.read_bytes();(self.support/'kimi-bridge/original-index.html').write_text('bad')
  with self.assertRaises(RuntimeError):uninstall(self.support,disable=False)
  self.assertEqual(self.index.read_bytes(),before)
 def test_unowned_asset_is_not_overwritten(self):
  (self.renderer/ASSET).write_text('not ours')
  with self.assertRaises(RuntimeError):self.put()
  self.assertEqual(self.index.read_bytes(),self.original)
if __name__=='__main__':unittest.main()
