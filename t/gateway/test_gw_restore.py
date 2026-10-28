"""Testes do gw-restore — comportamento com Ops mockado (nada real é tocado)."""
import importlib.util
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
HERE = os.path.dirname(os.path.abspath(__file__))
GW_PATH = os.path.join(HERE, "..", "..", "gateway", "gw-restore")

spec = importlib.util.spec_from_file_location(
    "gw_restore", GW_PATH, loader=SourceFileLoader("gw_restore", GW_PATH))
gw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gw)


def base_payload(**overrides):
    payload = {
        "snapshot": "backup/101/2026-10-27T10:00:00Z",
        "datastore": "bkp01",
        "ns": "cliente/a",
        "arquivo": "drive-scsi1.img",
        "particao": 2,
        "subpasta": "Dados/Users/joao",
        "vlan": 120,
        "gw_ip": "10.1.20.250",
        "prefix": 24,
        "vm_ip": "10.1.20.23",
        "horas": 4,
        "solicitante": "root@pve",
        "vmid_origem": "101",
        "chamado": "CH-9981",
    }
    payload.update(overrides)
    return payload


class FakeOps(gw.RealOps):
    def __init__(self, tmp, arping_rc=0, loop_exists=True, escape=False):
        self.tmp = tmp
        self.arping_rc = arping_rc
        self.loop_exists = loop_exists
        self.escape = escape
        self.calls = []

    def run(self, argv, stdin=None, timeout=None):
        self.calls.append((list(argv), stdin))
        prog = argv[0]
        if prog == "proxmox-backup-client" and argv[1] == "map":
            return {"rc": 0, "out": "map loop7\n", "err": ""}
        if prog == "id":
            return {"rc": 0, "out": "1042\n", "err": ""}
        if prog == "ip" and argv[1] == "link" and argv[2] == "show":
            return {"rc": 1, "out": "", "err": "não encontrado"}
        if prog == "arping":
            return {"rc": self.arping_rc, "out": "", "err": ""}
        if prog == "nft" and argv[1] == "-a":
            return {"rc": 0,
                    "out": "ip saddr ... accept # handle 15\n", "err": ""}
        return {"rc": 0, "out": "", "err": ""}

    def path_exists(self, path):
        if path.startswith("/dev/loop"):
            return self.loop_exists
        return os.path.exists(path)

    def realpath(self, path):
        if self.escape and "/mnt/" in path:
            return "/etc/passwd"
        return os.path.realpath(path)

    def read_file(self, path):
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()

    def tcp_connect(self, host, port, timeout=3.0):
        return True


class GatewayCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gwr-test-")
        self.ops = FakeOps(self.tmp)
        paths = {
            "lock_file": os.path.join(self.tmp, "run/gw-restore.lock"),
            "state_dir": os.path.join(self.tmp, "var/lib/sessions"),
            "state_archive_dir": os.path.join(self.tmp, "var/lib/archive"),
            "refcounts_file": os.path.join(self.tmp, "var/lib/refcounts.json"),
            "audit_log": os.path.join(self.tmp, "var/log/audit.log"),
            "sessions_root": os.path.join(self.tmp, "srv"),
            "samba_d_dir": os.path.join(self.tmp, "etc/samba/gw-restore.d"),
            "samba_conf": os.path.join(self.tmp, "etc/samba/gw-restore.conf"),
            "smb_conf": os.path.join(self.tmp, "etc/samba/smb.conf"),
            "pbs_env": os.path.join(self.tmp, "etc/gw-restore/pbs.env"),
            "keys_dir": os.path.join(self.tmp, "etc/gw-restore/keys"),
            "sysctl_conf": os.path.join(self.tmp, "90-gw-restore.conf"),
            "ntfs_plugin_candidates": (),
        }
        for key in ("state_dir", "state_archive_dir", "refcounts_file",
                    "audit_log", "samba_d_dir", "samba_conf", "smb_conf",
                    "pbs_env", "keys_dir", "sysctl_conf"):
            os.makedirs(os.path.dirname(paths[key]), exist_ok=True)
        with open(paths["pbs_env"], "w") as fh:
            fh.write("PBS_REPOSITORY=gwr@pbs@pbs.example:bkp01\n"
                     "PBS_FINGERPRINT=AA:BB\nTRUNK=ens20\n")
        with open(paths["smb_conf"], "w") as fh:
            fh.write("[global]\n  include = %s\n" % paths["samba_conf"])
        with open(paths["sysctl_conf"], "w") as fh:
            fh.write("net.ipv4.ip_forward = 0\n"
                     "net.ipv4.conf.all.rp_filter = 1\n")
        self.ctx = gw.Ctx(paths=paths, ops=self.ops)
        self.gwr = gw.GwRestore(ctx=self.ctx)

    def argvs(self, prog):
        return [a for (a, _s) in self.ops.calls if a[0] == prog]


class TestValidation(GatewayCase):
    def test_payload_valido(self):
        normalized = gw.validate_payload(base_payload())
        self.assertEqual(normalized["particao"], 2)

    def test_campos_invalidos(self):
        cases = [
            {"snapshot": "evil/../x"},            # snapshot fora do formato
            {"snapshot": "backup/101/nao-data"},
            {"datastore": "a b"},                 # espaço
            {"ns": "../etc"},
            {"arquivo": "../../etc/passwd"},
            {"particao": 0},
            {"particao": 256},
            {"subpasta": "../etc"},
            {"subpasta": "/abs"},
            {"subpasta": "a//b"},
            {"vlan": 0},
            {"vlan": 5000},
            {"gw_ip": "10.1.20.999"},
            {"vm_ip": "abc"},
            {"prefix": 33},
            {"horas": 0},
            {"horas": 300},
            {"solicitante": "user; rm -rf /"},
            {"chamado": "x" * 200},
        ]
        for overrides in cases:
            with self.assertRaises(
                    gw.GwError, msg="deveria recusar %r" % overrides):
                gw.validate_payload(base_payload(**overrides))

    def test_campo_obrigatorio_ausente(self):
        payload = base_payload()
        del payload["chamado"]
        with self.assertRaises(gw.GwError):
            gw.validate_payload(payload)


class TestPure(GatewayCase):
    def test_share_conf(self):
        conf = gw.render_share_conf(
            "8f3a2c", "/srv/gw-restore/sessions/8f3a2c/mnt/Dados",
            "10.1.20.23")
        for frag in ("[r-8f3a2c]", "read only = yes", "browseable = no",
                     "valid users = gwr-8f3a2c", "hosts allow = 10.1.20.23",
                     "hosts deny = ALL", "wide links = no",
                     "smb encrypt = required"):
            self.assertIn(frag, conf)
        self.assertIn("path = /srv/gw-restore/sessions/8f3a2c/mnt/Dados",
                      conf)

    def test_agregacao_idempotente(self):
        confs = [("b", "[r-b]\n  path = /b\n"), ("a", "[r-a]\n  path = /a\n")]
        first = gw.aggregate_includes(confs)
        second = gw.aggregate_includes(reversed(confs))
        self.assertEqual(first, second)
        self.assertLess(first.index("[r-a]"), first.index("[r-b]"))

    def test_confine_path(self):
        self.assertTrue(gw.confine_path("/srv/x/mnt", "/srv/x/mnt"))
        self.assertTrue(gw.confine_path("/srv/x/mnt", "/srv/x/mnt/sub"))
        self.assertFalse(gw.confine_path("/srv/x/mnt", "/srv/x"))
        self.assertFalse(gw.confine_path("/srv/x/mnt", "/etc/passwd"))
        self.assertFalse(gw.confine_path("/srv/x/mnt", "/srv/x/mntfoo"))

    def test_parse_loop_e_handle(self):
        self.assertEqual(gw.parse_loop_device("image map loop3\n"), "loop3")
        self.assertIsNone(gw.parse_loop_device("nada"))
        self.assertEqual(gw.parse_nft_handle("rule x # handle 42"), 42)
        self.assertIsNone(gw.parse_nft_handle("sem handle"))


class TestPublish(GatewayCase):
    def test_saida_json_estavel(self):
        result = self.gwr.publish(base_payload())
        self.assertEqual(sorted(result),
                         ["expires_at", "password", "unc", "user"])
        self.assertEqual(len(result["password"]), 32)
        self.assertTrue(result["unc"].startswith("\\\\10.1.20.250\\r-"))
        self.assertTrue(result["user"].startswith("gwr-"))

    def test_senha_nunca_em_estado_audit_ou_list(self):
        result = self.gwr.publish(base_payload())
        pwd = result["password"]
        state_files = os.listdir(self.ctx["state_dir"])
        self.assertEqual(len(state_files), 1)
        with open(os.path.join(self.ctx["state_dir"], state_files[0])) as fh:
            self.assertNotIn(pwd, fh.read())
        with open(self.ctx["audit_log"]) as fh:
            self.assertNotIn(pwd, fh.read())
        self.assertNotIn(pwd, self.gwr.list(as_json=True))
        # usuário do samba recebeu a senha via stdin do smbpasswd
        smb = [c for c in self.ops.calls if c[0][:2] == ["smbpasswd", "-a"]]
        self.assertEqual(1, len(smb))
        self.assertIn(pwd, smb[0][1])

    def test_duas_sessoes_mesmo_disco_um_map(self):
        self.gwr.publish(base_payload())
        self.gwr.publish(base_payload(subpasta="Dados/Outra",
                                      vm_ip="10.1.20.24"))
        map_calls = [a for (a, _s) in self.ops.calls
                     if a[:2] == ["proxmox-backup-client", "map"]]
        self.assertEqual(1, len(map_calls), "segundo publish reaproveita map")
        with open(self.ctx["refcounts_file"]) as fh:
            counts = json.load(fh)
        key = gw.map_key(gw.validate_payload(base_payload()))
        self.assertEqual(counts["maps"][key]["count"], 2)
        self.assertEqual(counts["vlans"]["120"], 2)
        # VLAN criada uma única vez
        add_vlan = [a for (a, _s) in self.ops.calls
                    if a[:3] == ["ip", "link", "add"]]
        self.assertEqual(1, len(add_vlan))

    def test_arping_ip_em_uso_aborta(self):
        self.ops.arping_rc = 1
        with self.assertRaises(gw.GwError) as cm:
            self.gwr.publish(base_payload())
        self.assertIn("já em uso", str(cm.exception))
        # não configurou IP nem levantou a interface
        argvs = [a for (a, _s) in self.ops.calls]
        self.assertFalse(any(a[:3] == ["ip", "addr", "add"] for a in argvs))
        # rollback: removeu a VLAN criada e o usuário
        self.assertTrue(any(a[:3] == ["ip", "link", "del"] for a in argvs))
        self.assertTrue(any(a[:1] == ["userdel"] for a in argvs))
        # nenhuma sessão persistiu
        self.assertFalse(os.path.isdir(self.ctx["state_dir"])
                         and os.listdir(self.ctx["state_dir"]))

    def test_path_traversal_recusado(self):
        # ".." já é recusado na validação do payload
        with self.assertRaises(gw.GwError):
            self.gwr.publish(base_payload(subpasta="Dados/../../etc"))
        # escape no realpath (symlink p/ fora) também aborta
        self.ops.escape = True
        with self.assertRaises(gw.GwError) as cm:
            self.gwr.publish(base_payload(subpasta="Dados/Users/joao"))
        self.assertIn("escapa", str(cm.exception))
        self.assertFalse(os.path.isdir(self.ctx["state_dir"])
                         and os.listdir(self.ctx["state_dir"]))


class TestRevokeGc(GatewayCase):
    def publish_two(self):
        first = self.gwr.publish(base_payload())
        second = self.gwr.publish(base_payload(subpasta="Dados/Outra",
                                               vm_ip="10.1.20.24"))
        return first, second


    def test_unmap_somente_no_ultimo_revoke(self):
        first, second = self.publish_two()
        self.gwr.revoke(first["user"][4:])
        unmaps = [a for (a, _s) in self.ops.calls
                  if a[:2] == ["proxmox-backup-client", "unmap"]]
        self.assertEqual(0, len(unmaps))
        with open(self.ctx["refcounts_file"]) as fh:
            counts = json.load(fh)
        self.assertEqual(counts["vlans"]["120"], 1)
        # share removido e regenerado sem ele
        with open(self.ctx["samba_conf"]) as fh:
            self.assertNotIn("r-%s" % first["user"][4:], fh.read())
        self.gwr.revoke(second["user"][4:])
        unmaps = [a for (a, _s) in self.ops.calls
                  if a[:2] == ["proxmox-backup-client", "unmap"]]
        self.assertEqual(1, len(unmaps))
        dels = [a for (a, _s) in self.ops.calls
                if a[:3] == ["ip", "link", "del"]]
        self.assertEqual(1, len(dels))
        # estado arquivado
        self.assertEqual(len(os.listdir(self.ctx["state_archive_dir"])), 2)

    def test_gc_revoga_vencida(self):
        result = self.gwr.publish(base_payload())
        sid = result["user"][4:]
        path = os.path.join(self.ctx["state_dir"], sid + ".json")
        with open(path) as fh:
            state = json.load(fh)
        state["expires_at"] = (
            datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
        with open(path, "w") as fh:
            json.dump(state, fh)
        out = self.gwr.gc()
        self.assertEqual(out["revoked"], [sid])
        self.assertEqual(os.listdir(self.ctx["state_dir"]), [])
        with open(self.ctx["audit_log"]) as fh:
            self.assertIn('"acao": "revoke"', fh.read())

    def test_gc_mantem_ativa(self):
        self.gwr.publish(base_payload())
        out = self.gwr.gc()
        self.assertEqual(out["revoked"], [])

    def test_boot_clean_remove_sobras_sem_map(self):
        result = self.gwr.publish(base_payload())
        sid = result["user"][4:]
        self.ops.loop_exists = False  # reboot: /dev/loop sumiu
        out = self.gwr.gc(boot=True)
        self.assertEqual(out["revoked"], [sid])
        unmaps = [a for (a, _s) in self.ops.calls
                  if a[:2] == ["proxmox-backup-client", "unmap"]]
        self.assertEqual(0, len(unmaps), "sem map vivo, sem unmap")
        self.assertEqual(os.listdir(self.ctx["state_dir"]), [])
        # usuário e share limpos
        self.assertTrue(any(a[:1] == ["userdel"] for (a, _s)
                            in self.ops.calls))

    def test_boot_gc_mantem_com_map_vivo(self):
        self.gwr.publish(base_payload())
        out = self.gwr.gc(boot=True)
        self.assertEqual(out["revoked"], [])

    def test_list_json(self):
        self.gwr.publish(base_payload())
        data = json.loads(self.gwr.list(as_json=True))
        self.assertEqual(len(data["sessions"]), 1)
        self.assertNotIn("password", json.dumps(data))


class TestSelfcheck(GatewayCase):
    def test_selfcheck_json_estavel(self):
        # falhas: sem plugin e sysctls "errados" (/proc não existe no tmp)
        data = json.loads(self.gwr.selfcheck(as_json=True))
        self.assertEqual(
            [c["name"] for c in data["checks"]],
            ["plugin-ntfs-dedup", "pbs-reachability", "pbs-token",
             "sysctls", "nft-table", "samba-include"])
        self.assertIn("ok", data)
        # samba-include passa: smb.conf de teste tem o include
        byname = {c["name"]: c for c in data["checks"]}
        self.assertTrue(byname["samba-include"]["ok"])
        self.assertFalse(byname["plugin-ntfs-dedup"]["ok"])


class TestEnvParsing(GatewayCase):
    def test_parse_env_file(self):
        env = gw.parse_env_file("# comentário\nA=1\n\nB=x y\n")
        self.assertEqual(env, {"A": "1", "B": "x y"})

    def test_expected_sysctls(self):
        expected = gw.expected_sysctls("# h\nnet.ipv4.ip_forward = 0\n")
        self.assertEqual(expected, {"net.ipv4.ip_forward": "0"})


if __name__ == "__main__":
    unittest.main()
