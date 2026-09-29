import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

source = Path(__file__).resolve().parents[2] / "infra" / "kubernetes" / "certificate.py"
spec = importlib.util.spec_from_file_location("certificate", source)
certificate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(certificate)


class CertificateTests(unittest.TestCase):
    def test_republishes_existing_certificate_even_when_certbot_does_not_renew(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cert_dir = root / "live" / "example.test"
            cert_dir.mkdir(parents=True)
            (cert_dir / "fullchain.pem").write_bytes(b"synthetic-certificate")
            (cert_dir / "privkey.pem").write_bytes(b"synthetic-private-key")
            account = root / "account"
            account.mkdir()
            (account / "token").write_text("synthetic-kubernetes-token")
            response = MagicMock()
            response.__enter__.return_value.status = 200
            with patch.object(certificate.subprocess, "run") as run, \
                 patch.object(certificate.ssl, "create_default_context"), \
                 patch.object(certificate.urllib.request, "urlopen", return_value=response) as send:
                certificate.reconcile("example.test", root / "live", account)
            self.assertIn("--keep-until-expiring", run.call_args.args[0])
            self.assertTrue(run.call_args.kwargs["check"])
            self.assertEqual(send.call_count, 1)
            request = send.call_args.args[0]
            self.assertEqual(request.method, "PATCH")
            body = json.loads(request.data)
            self.assertEqual(base64.b64decode(body["data"]["tls.crt"]), b"synthetic-certificate")
            self.assertEqual(base64.b64decode(body["data"]["tls.key"]), b"synthetic-private-key")
            self.assertEqual(body["type"], "kubernetes.io/tls")

    def test_certbot_failure_cannot_be_reported_as_published(self):
        with patch.object(certificate.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "certbot")), \
             patch.object(certificate.urllib.request, "urlopen") as send:
            with self.assertRaises(subprocess.CalledProcessError):
                certificate.reconcile("example.test")
            send.assert_not_called()

    def test_missing_certificate_cannot_be_published(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(certificate.subprocess, "run"), \
             patch.object(certificate.urllib.request, "urlopen") as send:
            with self.assertRaises(FileNotFoundError):
                certificate.reconcile("example.test", Path(directory))
            send.assert_not_called()

    def test_rejects_invalid_hostname_before_running_any_command(self):
        with patch.object(certificate.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                certificate.reconcile("../other")
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
