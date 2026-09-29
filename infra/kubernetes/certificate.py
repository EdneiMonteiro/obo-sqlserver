"""Obtain or reuse a certificate, then reconcile the Istio Secret every run."""

import base64
import json
import os
import re
import ssl
import subprocess
import urllib.request
from pathlib import Path


def reconcile(host, certificate_root=Path("/etc/letsencrypt/live"),
              service_account=Path("/var/run/secrets/kubernetes.io/serviceaccount")):
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", host):
        raise ValueError("PUBLIC_HOST must be a DNS hostname")
    subprocess.run([
        "certbot", "certonly", "--standalone", "--http-01-port", "8080",
        "--non-interactive", "--agree-tos", "--register-unsafely-without-email",
        "--keep-until-expiring", "--cert-name", host, "--domain", host,
    ], check=True)
    root = certificate_root / host
    body = {"data": {
        "tls.crt": base64.b64encode((root / "fullchain.pem").read_bytes()).decode(),
        "tls.key": base64.b64encode((root / "privkey.pem").read_bytes()).decode(),
    }, "type": "kubernetes.io/tls"}
    request = urllib.request.Request(
        "https://kubernetes.default.svc/api/v1/namespaces/aks-istio-ingress/secrets/obo-tls",
        data=json.dumps(body).encode(), method="PATCH",
        headers={"Content-Type": "application/merge-patch+json",
                 "Authorization": "Bearer " + (service_account / "token").read_text().strip()})
    context = ssl.create_default_context(cafile=str(service_account / "ca.crt"))
    with urllib.request.urlopen(request, context=context, timeout=30) as response:
        if response.status != 200:
            raise RuntimeError("Certificate publication failed")
    print("Certificate available and reconciled to Istio.")


if __name__ == "__main__":
    reconcile(os.environ["PUBLIC_HOST"])
