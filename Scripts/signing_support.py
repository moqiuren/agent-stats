"""Code signing identity discovery, deterministic selection, and local cert creation."""
import pathlib
import re
import secrets
import subprocess
import tempfile
from Scripts.packaging_support import PRODUCTS, ROOT

DEFAULT_CERT_NAME = 'Agent Stats Local Signer'
IDENTITY_RE = re.compile(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"([^"]+)"', re.MULTILINE)


def parse_identities(output):
    return IDENTITY_RE.findall(output or '')


def choose_strict_identity(output, requested=None):
    identities = parse_identities(output)
    if requested:
        matches = [fingerprint for fingerprint, name in identities if requested in (fingerprint, name)]
    else:
        matches = [fingerprint for fingerprint, _ in identities]
    if len(matches) != 1:
        raise RuntimeError('需要唯一、有效的代码签名证书；用 --signing-identity 指定。不能回退到会使辅助功能授权失效的临时签名。')
    return matches[0]


def select_preferred_identity(identities):
    if not identities:
        return None
    if len(identities) == 1:
        return identities[0][0]
    for prefix in ('Developer ID Application:', DEFAULT_CERT_NAME, 'Apple Development:'):
        for fingerprint, name in identities:
            if name == prefix or name.startswith(prefix):
                return fingerprint
    return identities[0][0]


def saved_identity_paths(root=ROOT, home=None):
    user_home = pathlib.Path(home) if home is not None else pathlib.Path.home()
    support_name = PRODUCTS['agent']['name']
    return [
        pathlib.Path(root) / '.build/signing-identity.txt',
        user_home / 'Library/Application Support' / support_name / 'signing-identity.txt',
    ]


def load_saved_identity(identities, root=ROOT, home=None):
    valid_fingerprints = {fingerprint for fingerprint, _ in identities}
    for path in saved_identity_paths(root=root, home=home):
        try:
            saved = path.read_text().strip()
        except OSError:
            continue
        if saved in valid_fingerprints:
            return saved
    return None


def save_identity(fingerprint, root=ROOT, home=None):
    for path in saved_identity_paths(root=root, home=home):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(fingerprint + '\n')


def find_valid_identities():
    result = subprocess.run(
        ['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
        check=True,
        capture_output=True,
        text=True,
    )
    return parse_identities(result.stdout)


def default_user_keychain(home=None):
    user_home = pathlib.Path(home) if home is not None else pathlib.Path.home()
    fallback = user_home / 'Library/Keychains/login.keychain-db'
    result = subprocess.run(
        ['/usr/bin/security', 'default-keychain', '-d', 'user'],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        path = result.stdout.strip().strip('"').strip("'")
        if path:
            return pathlib.Path(path)
    return fallback


def create_local_codesign_certificate(common_name=DEFAULT_CERT_NAME, home=None):
    keychain = default_user_keychain(home=home)
    passphrase = secrets.token_hex(16)
    with tempfile.TemporaryDirectory(prefix='agent-stats-cert-') as folder:
        stage = pathlib.Path(folder)
        config = stage / 'cert.cnf'
        key_file = stage / 'key.pem'
        cert_file = stage / 'cert.pem'
        existing = subprocess.run(
            ['/usr/bin/security', 'find-certificate', '-c', common_name, '-p', str(keychain)],
            capture_output=True,
            text=True,
        )
        if existing.returncode == 0 and 'BEGIN CERTIFICATE' in existing.stdout:
            cert_file.write_text(existing.stdout)
        else:
            p12_file = stage / 'cert.p12'
            config.write_text(
                '[req]\n'
                'distinguished_name=dn\n'
                'x509_extensions=ext\n'
                'prompt=no\n'
                '[dn]\n'
                f'CN={common_name}\n'
                '[ext]\n'
                'basicConstraints=critical,CA:TRUE\n'
                'keyUsage=critical,digitalSignature,keyCertSign\n'
                'extendedKeyUsage=critical,codeSigning\n'
            )
            subprocess.run(
                ['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                 '-keyout', str(key_file), '-out', str(cert_file),
                 '-days', '3650', '-config', str(config)],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ['/usr/bin/openssl', 'pkcs12', '-export',
                 '-inkey', str(key_file), '-in', str(cert_file),
                 '-out', str(p12_file), '-passout', f'pass:{passphrase}'],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ['/usr/bin/security', 'import', str(p12_file),
                 '-k', str(keychain), '-f', 'pkcs12', '-P', passphrase,
                 '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'],
                check=True,
                capture_output=True,
                text=True,
            )
        trust = subprocess.run(
            ['/usr/bin/security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign',
             '-k', str(keychain), str(cert_file)],
            capture_output=True,
            text=True,
        )
        if trust.returncode != 0:
            raise RuntimeError(
                f'已生成证书 "{common_name}"，但尚未完成信任授权；'
                '请在系统弹出的密码确认中允许修改信任，或在「钥匙串访问」中将它设为“始终信任”后重试。'
            )
    identities = find_valid_identities()
    matches = [fp for fp, name in identities if name == common_name]
    if not matches:
        raise RuntimeError(
            f'已导入证书 "{common_name}"，但系统仍未识别为有效代码签名证书；'
            '请在「钥匙串访问」检查该证书的代码签名信任设置后重试。'
        )
    return matches[-1]


def ensure_signing_identity(requested=None, root=ROOT, home=None, auto_create=False):
    if requested == '-':
        raise RuntimeError('不能使用临时签名（-），否则每次构建都会使辅助功能授权失效。')
    identities = find_valid_identities()
    if requested:
        matches = [fp for fp, name in identities if requested in (fp, name)]
        if len(matches) == 1:
            selected = matches[0]
        elif not matches and auto_create and requested == DEFAULT_CERT_NAME:
            selected = create_local_codesign_certificate(common_name=DEFAULT_CERT_NAME, home=home)
        else:
            raise RuntimeError(f'未找到唯一匹配的代码签名证书：{requested}')
        save_identity(selected, root=root, home=home)
        return selected

    saved = load_saved_identity(identities, root=root, home=home)
    if saved:
        save_identity(saved, root=root, home=home)
        return saved

    if auto_create:
        if identities:
            selected = select_preferred_identity(identities)
        else:
            selected = create_local_codesign_certificate(home=home)
        save_identity(selected, root=root, home=home)
        return selected

    if len(identities) != 1:
        raise RuntimeError('需要唯一、有效的代码签名证书；用 --signing-identity 指定（或传入 --auto-cert 自动创建/选择）。不能回退到会使辅助功能授权失效的临时签名。')
    selected = identities[0][0]
    save_identity(selected, root=root, home=home)
    return selected
