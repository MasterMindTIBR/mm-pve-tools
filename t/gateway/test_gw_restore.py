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
        "contract": 1,
        "request_id": "req-4f7f8c4b",
        "snapshot": "vm/101/2026-10-27T10:00:00Z",
        "datastore": "bkp01",
        "namespace": "cliente/a",
        "archive": "drive-scsi1.img",
        "partition": 2,
        "subpath": "Dados/Users/joao",
        "vlan": 120,
        "gw_ip": "10.1.20.250",
        "prefix": 24,
        "vm_ip": "10.1.20.23",
        "hours": 4,
        "requester": "root@pve",
        "source_vmid": 101,
        "target_vmid": 101,
        "ticket": "GLPI-9981",
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
        self.tcp_calls = []

    def run(self, argv, stdin=None, timeout=None, env=None):
        self.calls.append((list(argv), stdin))
        prog = argv[0]
        if prog == "proxmox-backup-client" and argv[1] == "map":
            return {"rc": 0, "out": "map loop7\n", "err": ""}
        if prog == "mount":
            return {"rc": 0, "out": "", "err": ""}
        if prog == "id":
            return {"rc": 0, "out": "1042\n", "err": ""}
        if prog == "ip" and argv[1] == "link" and argv[2] == "show":
            return {"rc": 1, "out": "", "err": "não encontrado"}
        if prog == "arping":
            return {"rc": self.arping_rc, "out": "", "err": ""}
        if prog == "nft" and argv[1:3] == ["--echo", "--handle"]:
            return {"rc": 0,
                    "out": "ip saddr ... accept # handle 15\n", "err": ""}
        return {"rc": 0, "out": "", "err": ""}

    def path_exists(self, path):
        if path.startswith("/dev/loop"):
            return self.loop_exists and (not path.endswith("p2") or self.loop_exists)
        return os.path.exists(path)

    def realpath(self, path):
        if self.escape and "Dados" in path:
            return "/etc/passwd"
        return os.path.realpath(path)

    def read_file(self, path):
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()

    def tcp_connect(self, host, port, timeout=3.0):
        self.tcp_calls.append((host, port, timeout))
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
        paths.update({
            "intent_dir": os.path.join(self.tmp, "var/lib/intents"),
            "request_locks_dir": os.path.join(self.tmp, "run/requests"),
            "mounts_root": os.path.join(self.tmp, "srv/mounts"),
        })
        for key in ("state_dir", "state_archive_dir", "refcounts_file",
                    "audit_log", "intent_dir", "request_locks_dir",
                    "mounts_root", "samba_d_dir", "samba_conf", "smb_conf",
                    "pbs_env", "keys_dir", "sysctl_conf"):
            os.makedirs(os.path.dirname(paths[key]), exist_ok=True)
        with open(paths["pbs_env"], "w") as fh:
            fh.write("PBS_SERVER=pbs.example:8007\nPBS_USER=gwr@pbs!gateway\n"
                     "PBS_PASSWORD=token\nPBS_FINGERPRINT=AA:BB\n"
                     "PBS_DATASTORES=bkp01\nTRUNK=ens20\n")
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
            {"snapshot": "evil/../x"},
            {"snapshot": "vm/101/nao-data"},
            {"datastore": "a b"},
            {"namespace": "../etc"},
            {"archive": "../../etc/passwd"},
            {"partition": 0},
            {"partition": 256},
            {"subpath": "../etc"},
            {"subpath": "/abs"},
            {"subpath": "a//b"},
            {"vlan": 0},
            {"vlan": 5000},
            {"gw_ip": "10.1.20.999"},
            {"vm_ip": "abc"},
            {"prefix": 33},
            {"hours": 0},
            {"hours": 300},
            {"requester": ""},
            {"ticket": "x" * 200},
        ]
        for overrides in cases:
            with self.assertRaises(
                    gw.GwError, msg="deveria recusar %r" % overrides):
                gw.validate_payload(base_payload(**overrides))

    def test_campo_obrigatorio_ausente(self):
        payload = base_payload()
        del payload["ticket"]
        with self.assertRaises(gw.GwError):
            gw.validate_payload(payload)


class TestPure(GatewayCase):
    def test_share_conf(self):
        conf = gw.render_share_conf(
            "8f3a2c", "/srv/gw-restore/sessions/8f3a2c/mnt/Dados",
            "10.1.20.23")
        for frag in ("[r-8f3a2c]", "read only = yes", "browseable = yes",
                     "valid users = gwr-8f3a2c", "hosts allow = 10.1.20.23",
                     "hosts deny = ALL", "wide links = no",
                     "smb encrypt = required"):
            self.assertIn(frag, conf)
        self.assertIn("path = /srv/gw-restore/sessions/8f3a2c/mnt/Dados",
                      conf)

    def test_share_path_escapa_percentual_do_samba(self):
        self.assertIn("100%% seguro", gw.render_share_conf(
            "abc123", "/srv/100% seguro", "10.1.20.23"))

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

    def test_parse_pbs_server(self):
        self.assertEqual(gw.parse_pbs_server("pbs.example"),
                         ("pbs.example", 8007))
        self.assertEqual(gw.parse_pbs_server("pbs.example:8443"),
                         ("pbs.example", 8443))
        self.assertEqual(gw.parse_pbs_server("[2001:db8::5]:9443"),
                         ("2001:db8::5", 9443))
        self.assertEqual(gw.parse_pbs_server("2001:db8::5"), (None, None))


class TestPublish(GatewayCase):
    def test_repository_usa_usuario_token_servidor_e_porta(self):
        self.gwr.publish(base_payload())
        map_call = next(a for a, _s in self.ops.calls
                        if a[:2] == ["proxmox-backup-client", "map"])
        repository = map_call[map_call.index("--repository") + 1]
        self.assertEqual(repository,
                         "gwr@pbs!gateway@pbs.example:8007:bkp01")

    def test_saida_json_estavel(self):
        result = self.gwr.publish(base_payload())
        self.assertEqual(sorted(result),
                         ["expires_at", "password", "request_id", "unc", "user"])
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
        self.gwr.publish(base_payload(subpath="Dados/Outra",
                                      vm_ip="10.1.20.24",
                                      request_id="req-4f7f8c4c"))
        map_calls = [a for (a, _s) in self.ops.calls
                     if a[:2] == ["proxmox-backup-client", "map"]]
        self.assertEqual(1, len(map_calls), "segundo publish reaproveita map")
        with open(self.ctx["refcounts_file"]) as fh:
            counts = json.load(fh)
        key = gw.map_key(gw.validate_payload(base_payload()))
        self.assertEqual(counts["maps"][key]["count"], 2)
        self.assertEqual(counts["vlans"]["120"], 2)
        mounts = [a for a, _s in self.ops.calls if a[:2] == ["mount", "-t"]]
        self.assertEqual(len(mounts), 1)
        self.assertNotIn("uid=", mounts[0][4])
        self.assertNotIn("gid=", mounts[0][4])
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
            self.gwr.publish(base_payload(subpath="Dados/../../etc"))
        # escape no realpath (symlink p/ fora) também aborta
        self.ops.escape = True
        with self.assertRaises(gw.GwError) as cm:
            self.gwr.publish(base_payload(subpath="Dados/Users/joao"))
        self.assertIn("escapa", str(cm.exception))
        self.assertFalse(os.path.isdir(self.ctx["state_dir"])
                         and os.listdir(self.ctx["state_dir"]))

    def test_retry_request_id_reusa_sessao_e_troca_senha(self):
        first = self.gwr.publish(base_payload())
        second = self.gwr.publish(base_payload())
        self.assertEqual(first["user"], second["user"])
        self.assertEqual(first["unc"], second["unc"])
        self.assertNotEqual(first["password"], second["password"])
        self.assertEqual(len([a for a, _s in self.ops.calls
                              if a[:2] == ["proxmox-backup-client", "map"]]), 1)
        self.assertEqual(len(os.listdir(self.ctx["state_dir"])), 1)

    def test_retry_concorrente_recebe_busy(self):
        lock = self.gwr._request_lock("req-4f7f8c4b")
        try:
            with self.assertRaises(gw.GwError) as cm:
                self.gwr.publish(base_payload())
            self.assertEqual(cm.exception.code, "busy")
            error = gw.validate_contract("publish_error", {
                "contract": 1, "request_id": "req-4f7f8c4b",
                "error": cm.exception.code, "message": str(cm.exception),
            })
            self.assertEqual(error["error"], "busy")
        finally:
            lock.close()

    def test_datastore_fora_da_allowlist_recusado(self):
        with self.assertRaises(gw.GwError) as cm:
            self.gwr.publish(base_payload(datastore="outro"))
        self.assertIn("allowlist PBS_DATASTORES", str(cm.exception))

    def test_crash_injetado_reconcilia_sem_senha_persistida(self):
        for step in ("map", "mount", "vlan", "nft", "samba", "state"):
            with self.subTest(step=step):
                self.setUp()
                os.environ["GW_RESTORE_FAIL_AFTER"] = step
                try:
                    with self.assertRaises(gw.CrashInjected):
                        self.gwr.publish(base_payload())
                finally:
                    os.environ.pop("GW_RESTORE_FAIL_AFTER", None)
                # Um crash antes do state deixa um intent recuperável; depois
                # do state o retry encontra a sessão e só troca a senha.
                result = self.gwr.publish(base_payload())
                self.assertEqual(result["request_id"], "req-4f7f8c4b")
                self.assertEqual(len(os.listdir(self.ctx["state_dir"])), 1)
                self.assertEqual(os.listdir(self.ctx["intent_dir"]), [])
                for root, _dirs, files in os.walk(self.tmp):
                    for name in files:
                        with open(os.path.join(root, name), encoding="utf-8",
                                  errors="ignore") as handle:
                            self.assertNotIn(result["password"], handle.read())


class TestRevokeGc(GatewayCase):
    def publish_two(self):
        first = self.gwr.publish(base_payload())
        second = self.gwr.publish(base_payload(subpath="Dados/Outra",
                                               vm_ip="10.1.20.24",
                                               request_id="req-4f7f8c4c"))
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

    def test_boot_gc_revoga_sessoes_ativas(self):
        self.gwr.publish(base_payload())
        out = self.gwr.gc(boot=True)
        self.assertEqual(len(out["revoked"]), 1)

    def test_list_json(self):
        self.gwr.publish(base_payload())
        data = json.loads(self.gwr.list(as_json=True))
        self.assertEqual(len(data["sessions"]), 1)
        self.assertNotIn("password", json.dumps(data))

    def test_retry_depois_de_revoke_e_terminal(self):
        result = self.gwr.publish(base_payload())
        self.gwr.revoke(result["user"][4:])
        with self.assertRaises(gw.GwError) as cm:
            self.gwr.publish(base_payload())
        self.assertEqual(cm.exception.code, "session_gone")

    def test_expiry_inparseavel_e_expirada(self):
        result = self.gwr.publish(base_payload())
        path = os.path.join(self.ctx["state_dir"], result["user"][4:] + ".json")
        with open(path, encoding="utf-8") as handle:
            state = json.load(handle)
        state["expires_at"] = "nao-e-data"
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(state, handle)
        out = self.gwr.gc()
        self.assertEqual(out["revoked"], [result["user"][4:]])


class TestSelfcheck(GatewayCase):
    def test_selfcheck_json_estavel(self):
        # falhas: sem plugin e sysctls "errados" (/proc não existe no tmp)
        data = json.loads(self.gwr.selfcheck(as_json=True))
        self.assertEqual(
            [c["name"] for c in data["checks"]],
            ["plugin-ntfs-dedup", "pbs-reachability", "pbs-token",
             "sysctls", "nft-table", "nft-smb-only-vlan", "samba-include"])
        self.assertIn("ok", data)
        # samba-include passa: smb.conf de teste tem o include
        byname = {c["name"]: c for c in data["checks"]}
        self.assertTrue(byname["samba-include"]["ok"])
        self.assertFalse(byname["plugin-ntfs-dedup"]["ok"])
        self.assertNotIn("detail", byname["pbs-reachability"])
        self.assertNotIn("detail", byname["samba-include"])
        self.assertIn("detail", byname["plugin-ntfs-dedup"])

    def test_selfcheck_pbs_ipv6_host_e_porta(self):
        with open(self.ctx["pbs_env"], "w") as fh:
            fh.write("PBS_SERVER=[2001:db8::5]:9443\n"
                     "PBS_USER=gwr@pbs!gateway\nPBS_PASSWORD=token\n"
                     "PBS_FINGERPRINT=AA:BB\nPBS_DATASTORES=bkp01\n")
        self.gwr.selfcheck(as_json=True)
        self.assertEqual(self.ops.tcp_calls[-1], ("2001:db8::5", 9443, 3.0))


class TestEnvParsing(GatewayCase):
    def test_realops_executa_true(self):
        result = gw.RealOps().run(["true"])
        self.assertEqual(result["rc"], 0)

    def test_parse_env_file(self):
        env = gw.parse_env_file("# comentário\nA=1\n\nB=x y\n")
        self.assertEqual(env, {"A": "1", "B": "x y"})

    def test_expected_sysctls(self):
        expected = gw.expected_sysctls("# h\nnet.ipv4.ip_forward = 0\n")
        self.assertEqual(expected, {"net.ipv4.ip_forward": "0"})


class TestContractFixtures(unittest.TestCase):
    """Fixtures compartilhadas contract/fixtures/*.json: o nome do arquivo
    (sem extensão) é a definição do schema. O MESMO arquivo é validado em
    t/contract/01_fixtures.t (Perl, lado node) contra o MESMO
    contract/gw-restore.v1.schema.json. Renomear um campo de um lado sem
    atualizar o schema/fixture quebra os dois testes."""

    FIXTURES_DIR = os.path.join(HERE, "..", "..", "contract", "fixtures")

    def test_fixtures_presentes(self):
        files = [f for f in os.listdir(self.FIXTURES_DIR) if f.endswith(".json")]
        self.assertGreaterEqual(len(files), 6)

    def test_cada_fixture_valida_contra_o_schema(self):
        for filename in sorted(os.listdir(self.FIXTURES_DIR)):
            if not filename.endswith(".json"):
                continue
            definition = filename[: -len(".json")]
            with open(os.path.join(self.FIXTURES_DIR, filename),
                      encoding="utf-8") as handle:
                value = json.load(handle)
            with self.subTest(fixture=filename):
                gw.validate_contract(definition, value)


if __name__ == "__main__":
    unittest.main()
